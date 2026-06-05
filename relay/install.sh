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
ENV_FILE="$ENV_DIR/relay.env"
ENV_EXAMPLE="$SCRIPT_DIR/../config/relay.env.example"
REALM_CONFIG="/etc/realm/config.toml"

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
    log "INFO" "using existing relay env: $ENV_FILE"
    return 0
  fi

  [[ -f "$ENV_EXAMPLE" ]] || die "relay env example not found: $ENV_EXAMPLE"
  install -m 0600 "$ENV_EXAMPLE" "$ENV_FILE"
  log "WARN" "created $ENV_FILE from example"
  return 1
}

env_has_placeholders() {
  grep -Eq 'relay-backend\.example\.com|receiver1\.example\.com|1\.2\.3\.4|2001:db8' "$ENV_FILE"
}

realm_config_is_ready() {
  [[ -f "$REALM_CONFIG" ]] && grep -q '[^[:space:]]' "$REALM_CONFIG"
}

run_step() {
  local script_name="${1:?script name is required}"

  log "INFO" "running relay/${script_name}"
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

if [[ "$env_created" == "true" ]]; then
  log "WARN" "edit $ENV_FILE, then rerun: sudo ./install.sh"
  exit 0
fi

if env_has_placeholders; then
  die "$ENV_FILE still contains example placeholder targets; edit it before rerunning install.sh"
fi

run_step setup-realm-service.sh

if ! realm_config_is_ready; then
  log "WARN" "$REALM_CONFIG is empty or missing"
  log "WARN" "edit $REALM_CONFIG, then run: sudo systemctl restart realm.service"
  log "WARN" "after realm config is ready, rerun: sudo ./install.sh"
  exit 0
fi

run_step install-qos-service.sh
run_step install-cover-sender.sh

log "INFO" "relay installation complete"
"$SCRIPT_DIR/status.sh" || true
