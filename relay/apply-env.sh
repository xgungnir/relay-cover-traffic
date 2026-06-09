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

ENV_FILE="/etc/relay-cover-traffic/relay.env"
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"
ENV_EXAMPLE="$SCRIPT_DIR/../config/relay.env.example"
sender_was_running=0

require_config_env_file "$ENV_SOURCE" "$ENV_EXAMPLE"

env_has_placeholders() {
  grep -Eq 'relay-backend\.example\.com|receiver1\.example\.com|1\.2\.3\.4|2001:db8' "$ENV_SOURCE"
}

service_is_running() {
  local unit="${1:?unit is required}"
  local state=""

  state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  [[ "$state" == "active" || "$state" == "activating" ]]
}

run_step() {
  local script_name="${1:?script name is required}"

  log "INFO" "running relay/${script_name}"
  "$SCRIPT_DIR/$script_name"
}

require_root
require_cmd systemctl grep

if env_has_placeholders; then
  die "$ENV_SOURCE still contains example placeholder targets; edit it before rerunning apply-env.sh"
fi

if service_is_running relay-cover-sender.service; then
  sender_was_running=1
  log "INFO" "stopping active relay-cover-sender.service before applying new env"
  systemctl stop relay-cover-sender.service
fi

if service_is_running relay-cover-qos.service; then
  log "INFO" "stopping relay-cover-qos.service so old QoS state is removed before env sync"
  systemctl stop relay-cover-qos.service
fi

sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"

run_step install-qos-service.sh
run_step install-cover-sender.sh

if [[ "$sender_was_running" -eq 1 ]]; then
  log "INFO" "restarting relay-cover-sender.service with updated env"
  systemctl start relay-cover-sender.service
fi

log "INFO" "relay env changes applied"
