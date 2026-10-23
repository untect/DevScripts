#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/yattee/yattee-server

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
catch_errors
setting_up_container
network_check
update_os

APP_DIR="/opt/yattee-server"

msg_info "Installing Dependencies"
$STD apt install -y ffmpeg
msg_ok "Installed Dependencies"

# Runtimes: Node.js >= 22 (web UI assets + PO-token provider build), Python 3.12+ via uv,
# Deno (required by yt-dlp for YouTube JS challenge solving)
NODE_VERSION="22" setup_nodejs
PYTHON_VERSION="3.12" setup_uv
fetch_and_deploy_gh_release "deno-runtime" "denoland/deno" "prebuild" "latest" "/opt/deno" "deno-$(uname -m)-unknown-linux-gnu.zip"
ln -sf /opt/deno/deno /usr/local/bin/deno

fetch_and_deploy_gh_release "yattee-server" "yattee/yattee-server" "tarball" "latest" "$APP_DIR"
mkdir -p "$APP_DIR/data" "$APP_DIR/downloads" "$APP_DIR/static"
chmod 700 "$APP_DIR/data"

msg_info "Installing Python Dependencies (incl. yt-dlp)"
$STD uv venv --python 3.12 "$APP_DIR/.venv"
$STD uv pip install -r "$APP_DIR/requirements.txt" --python "$APP_DIR/.venv/bin/python"
msg_ok "Installed Python Dependencies"

msg_info "Installing Web UI Assets"
cd "$APP_DIR" || exit 1
$STD npm ci --no-audit --no-fund
rm -rf "$APP_DIR/node_modules"
msg_ok "Installed Web UI Assets"

# bgutil PO-token provider: version is pinned in requirements.txt and must match the pip plugin.
# Built into the same layout the upstream Dockerfile uses (/opt/bgutil-pot-provider).
# Keep in sync with build_pot_provider() in ct/yattee-server.sh.
POT_VERSION="$(grep -oP 'bgutil-ytdlp-pot-provider==\K[0-9.]+' "$APP_DIR/requirements.txt" || true)"
POT_VERSION="${POT_VERSION:-1.3.2}"
CLEAN_INSTALL=1 fetch_and_deploy_gh_release "bgutil-pot-provider" "Brainicism/bgutil-ytdlp-pot-provider" "tarball" "$POT_VERSION" "/opt/bgutil-pot-provider-src"
msg_info "Building bgutil PO Token Provider ${POT_VERSION}"
cd /opt/bgutil-pot-provider-src/server || exit 1
# Upstream binds to all interfaces without authentication; yattee-server only uses 127.0.0.1:4416
sed -i -E 's/host: "(::|0\.0\.0\.0)"/host: "127.0.0.1"/' src/main.ts
if grep -qE 'host: "(::|0\.0\.0\.0)"' src/main.ts; then
  msg_error "Could not restrict the PO token provider to localhost"
  exit 1
fi
$STD npm ci --no-audit --no-fund
$STD npx tsc
test -f build/main.js
$STD npm ci --omit=dev --no-audit --no-fund
mkdir -p /opt/bgutil-pot-provider/bin
cp -r build node_modules package.json /opt/bgutil-pot-provider/
# Symlink (not copy) so Node.js security updates also apply to the provider
ln -sf "$(command -v node)" /opt/bgutil-pot-provider/bin/node
cd / || exit 1
rm -rf /opt/bgutil-pot-provider-src
msg_ok "Built bgutil PO Token Provider ${POT_VERSION}"

msg_info "Configuring Yattee Server"
cat <<EOF >"$APP_DIR/.env"
# Yattee Server startup configuration (see docs/configuration.md in the repo)
HOST=0.0.0.0
PORT=8085
DATA_DIR=${APP_DIR}/data
DOWNLOAD_DIR=${APP_DIR}/downloads

# The container is served over plain HTTP by default. Set to true once the
# server sits behind an HTTPS reverse proxy, otherwise admin login cookies
# are only sent over HTTPS.
SECURE_COOKIES=false

# Optional auto-provisioning (skips the setup wizard):
# ADMIN_USERNAME=
# ADMIN_PASSWORD=
# INVIDIOUS_INSTANCE_URL=

# Optional egress proxy for YouTube-bound traffic:
# YT_EGRESS_PROXY=http://user:pass@host:port
EOF
chmod 600 "$APP_DIR/.env"
msg_ok "Configured Yattee Server"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/yattee-server.service
[Unit]
Description=Yattee Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=PATH=${APP_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${APP_DIR}/.venv/bin/uvicorn server:app --host \${HOST} --port \${PORT} --log-level info
Restart=on-failure
RestartSec=5
# Database and encryption keys are created private; no privilege escalation from child processes
UMask=0077
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now yattee-server
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
