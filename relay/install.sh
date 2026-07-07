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

ENV_FILE="${RELAY_RUNTIME_ENV_FILE:-/etc/relay-cover-traffic/relay.env}"
ENV_SOURCE="${RELAY_CANDIDATE_ENV_FILE:-$SCRIPT_DIR/../config/relay.env}"
ENV_EXAMPLE="${RELAY_CANDIDATE_ENV_EXAMPLE:-$SCRIPT_DIR/../config/relay.env.example}"

require_debian_like() {
  local os_id=""
  local os_like=""

  if [[ "${RELAY_TEST_SKIP_OS_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  [[ -r /etc/os-release ]] || die "/etc/os-release not found; this installer expects Debian-like Linux"
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_like="${ID_LIKE:-}"

  [[ "$os_id" == "debian" || "$os_like" == *"debian"* ]] || \
    die "unsupported OS: ID=${os_id:-unknown} ID_LIKE=${os_like:-unknown}; this installer expects Debian-like Linux"
}

run_step() {
  local script_name="${1:?script name is required}"

  log "INFO" "running relay/${script_name}"
  bash "$SCRIPT_DIR/$script_name"
}

main() {
  require_config_env_file "$ENV_SOURCE" "$ENV_EXAMPLE"
  require_root
  require_cmd install mktemp mv systemctl ip grep
  require_debian_like

  load_and_validate_relay_env "$ENV_SOURCE" 1
  require_no_legacy_relay_resources
  log "INFO" "validated relay candidate config: EGRESS_DEV=$EGRESS_DEV COVER_RATE=${RELAY_COVER_RATE_BPS}bps COVER_DURATION_RANGE=$COVER_DURATION_RANGE COVER_TYPE=$COVER_TYPE target_count=$RELAY_VALIDATED_TARGET_COUNT"

  run_step install-deps.sh
  require_relay_iperf3_capabilities

  install_private_file_atomically "$ENV_SOURCE" "$ENV_FILE"
  log "INFO" "installed validated relay runtime env to $ENV_FILE"

  run_step install-cover-sender.sh
  systemctl enable --now relay-cover-sender.timer
  log "INFO" "relay-cover-sender.timer installed and enabled"

  log "INFO" "relay installation complete"
  if [[ "${RELAY_TEST_SKIP_STATUS:-0}" != "1" ]]; then
    bash "$SCRIPT_DIR/status.sh" || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
