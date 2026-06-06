#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/../common/lib.sh" ]]; then
  # shellcheck source=common/lib.sh
  source "$SCRIPT_DIR/../common/lib.sh"
else
  echo "common library not found" >&2
  exit 1
fi

ENV_DIR="/etc/relay-cover-traffic"
ENV_FILE="$ENV_DIR/receiver.env"
ENV_SOURCE="$SCRIPT_DIR/../config/receiver.env"
ENV_EXAMPLE="$SCRIPT_DIR/../config/receiver.env.example"
SING_BOX_CONFIG="/etc/sing-box/config.json"

require_config_env_file "$ENV_SOURCE" "$ENV_EXAMPLE"

require_debian_like() {
  local os_id=""
  local os_like=""

  [[ -r /etc/os-release ]] || die "/etc/os-release not found; this installer expects Debian-like Linux"
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  [[ "$os_id" == "debian" || "$os_like" == *"debian"* ]] || \
    die "unsupported OS: ID=${os_id:-unknown} ID_LIKE=${os_like:-unknown}; this installer expects Debian-like Linux"
}

env_has_placeholders() {
  grep -Eq '5\.6\.7\.8|5\.6\.7\.9|2001:db8' "$ENV_SOURCE"
}

warn_sing_box_config() {
  if [[ -s "$SING_BOX_CONFIG" ]]; then
    log "INFO" "sing-box config exists and is non-empty: $SING_BOX_CONFIG"
  else
    log "WARN" "$SING_BOX_CONFIG is missing or empty; configure sing-box separately before relying on the downstream service"
  fi
}

run_step() {
  local script_name="${1:?script name is required}"

  log "INFO" "running receiver/${script_name}"
  "$SCRIPT_DIR/$script_name"
}

require_root
require_cmd install grep
require_debian_like

if env_has_placeholders; then
  die "$ENV_SOURCE still contains example whitelist entries; edit it before rerunning install.sh"
fi

sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"

run_step install-deps.sh
warn_sing_box_config

run_step setup-iperf3-receiver.sh
run_step setup-firewall.sh

log "INFO" "receiver installation complete"
"$SCRIPT_DIR/status.sh" || true
