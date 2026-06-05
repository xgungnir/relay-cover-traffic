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
ENV_EXAMPLE="$SCRIPT_DIR/../config/receiver.env.example"
SING_BOX_CONFIG="/etc/sing-box/config.json"

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

ensure_env_file() {
  install -d -m 0755 "$ENV_DIR"

  if [[ -f "$ENV_FILE" ]]; then
    log "INFO" "using existing receiver env: $ENV_FILE"
    return 0
  fi

  [[ -f "$ENV_EXAMPLE" ]] || die "receiver env example not found: $ENV_EXAMPLE"
  install -m 0600 "$ENV_EXAMPLE" "$ENV_FILE"
  log "WARN" "created $ENV_FILE from example"
  return 1
}

env_has_placeholders() {
  grep -Eq '5\.6\.7\.8|5\.6\.7\.9|2001:db8' "$ENV_FILE"
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

env_created="false"

require_root
require_cmd install grep
require_debian_like

if ! ensure_env_file; then
  env_created="true"
fi

run_step install-deps.sh
warn_sing_box_config

if [[ "$env_created" == "true" ]]; then
  log "WARN" "edit $ENV_FILE, then rerun: sudo ./install.sh"
  exit 0
fi

if env_has_placeholders; then
  die "$ENV_FILE still contains example whitelist entries; edit it before rerunning install.sh"
fi

run_step setup-iperf3-receiver.sh
run_step setup-firewall.sh

log "INFO" "receiver installation complete"
"$SCRIPT_DIR/status.sh" || true
