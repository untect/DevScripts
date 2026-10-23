#!/usr/bin/env bash
# NOTE: point this at the raw root of YOUR fork/repo that contains ct/ and install/
# (the docs use the DevScripts URL for new applications under test)
_CS_DEFAULT_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USER/YOUR_REPO/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")

# Copyright (c) 2021-2026 community-scripts ORG
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/yattee/yattee-server

APP="Yattee Server"
var_tags="${var_tags:-media;youtube;yt-dlp}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
var_arm64="${var_arm64:-yes}"

header_info "$APP"
variables
color
catch_errors

# Builds the bgutil PO-token provider into the layout the upstream Dockerfile uses.
# Keep in sync with install/yattee-server-install.sh (the CT script runs inside the
# container on update; it cannot share code with the install script).
function build_pot_provider() {
  local ver="$1"
  CLEAN_INSTALL=1 fetch_and_deploy_gh_release "bgutil-pot-provider" "Brainicism/bgutil-ytdlp-pot-provider" "tarball" "$ver" "/opt/bgutil-pot-provider-src"
  msg_info "Building bgutil PO Token Provider ${ver}"
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
  rm -rf /opt/bgutil-pot-provider
  mkdir -p /opt/bgutil-pot-provider/bin
  cp -r build node_modules package.json /opt/bgutil-pot-provider/
  # Symlink (not copy) so Node.js security updates also apply to the provider
  ln -sf "$(command -v node)" /opt/bgutil-pot-provider/bin/node
  cd / || exit 1
  rm -rf /opt/bgutil-pot-provider-src
  msg_ok "Built bgutil PO Token Provider ${ver}"
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/yattee-server/.venv ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # Stop first: Deno/Node binaries cannot be replaced while yt-dlp or the PO token provider runs them
  msg_info "Stopping Service"
  systemctl stop yattee-server
  msg_ok "Stopped Service"

  NODE_VERSION="22" setup_nodejs
  PYTHON_VERSION="3.12" setup_uv

  if check_for_gh_release "yattee-server" "yattee/yattee-server"; then
    create_backup /opt/yattee-server/data /opt/yattee-server/.env

    # Clean deploy so files removed upstream (e.g. old migrations) do not linger
    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "yattee-server" "yattee/yattee-server" "tarball" "latest" "/opt/yattee-server"

    restore_backup
    mkdir -p /opt/yattee-server/data /opt/yattee-server/downloads /opt/yattee-server/static
    chmod 700 /opt/yattee-server/data

    msg_info "Rebuilding Python Environment"
    $STD uv venv --python 3.12 /opt/yattee-server/.venv
    $STD uv pip install -r /opt/yattee-server/requirements.txt --python /opt/yattee-server/.venv/bin/python
    msg_ok "Rebuilt Python Environment"

    msg_info "Updating Web UI Assets"
    cd /opt/yattee-server || exit
    $STD npm ci --no-audit --no-fund
    rm -rf /opt/yattee-server/node_modules
    msg_ok "Updated Web UI Assets"

    # The PO-token provider version is pinned in requirements.txt and must match
    POT_VERSION="$(grep -oP 'bgutil-ytdlp-pot-provider==\K[0-9.]+' /opt/yattee-server/requirements.txt || true)"
    if [[ -n "$POT_VERSION" ]] && check_for_gh_release "bgutil-pot-provider" "Brainicism/bgutil-ytdlp-pot-provider" "$POT_VERSION"; then
      build_pot_provider "$POT_VERSION"
    fi
  fi

  # Always refresh yt-dlp: YouTube extraction breaks often between app releases.
  # Only yt-dlp is upgraded; other dependencies stay at what the release specifies.
  msg_info "Updating yt-dlp"
  $STD uv pip install --upgrade yt-dlp --python /opt/yattee-server/.venv/bin/python
  msg_ok "Updated yt-dlp"

  if check_for_gh_release "deno-runtime" "denoland/deno"; then
    fetch_and_deploy_gh_release "deno-runtime" "denoland/deno" "prebuild" "latest" "/opt/deno" "deno-$(uname -m)-unknown-linux-gnu.zip"
  fi

  msg_info "Starting Service"
  systemctl start yattee-server
  msg_ok "Started Service"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Open the setup wizard now to create your admin account:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP:-<container-ip>}:8085${CL}"
