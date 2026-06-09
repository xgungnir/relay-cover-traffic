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
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"
ENV_EXAMPLE="$SCRIPT_DIR/../config/relay.env.example"

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
  grep -Eq 'relay-backend\.example\.com|receiver1\.example\.com|1\.2\.3\.4|2001:db8' "$ENV_SOURCE"
}

run_step() {
  local script_name="${1:?script name is required}"

  log "INFO" "running relay/${script_name}"
  "$SCRIPT_DIR/$script_name"
}

require_root
require_cmd install grep
require_debian_like

if env_has_placeholders; then
  die "$ENV_SOURCE still contains example placeholder targets; edit it before rerunning install.sh"
fi

sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"

run_step install-deps.sh

run_step setup-sb-service.sh

run_step install-qos-service.sh
run_step install-cover-sender.sh

log "INFO" "relay installation complete"
"$SCRIPT_DIR/status.sh" || true
