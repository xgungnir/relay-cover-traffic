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
ports=()

collect_target_ports() {
  local raw_targets="${1:?target list is required}"
  local _host
  local port

  while IFS=$'\t' read -r _host port; do
    ports+=("$port")
  done < <(parse_target_list "$raw_targets")
}

port_regex() {
  local IFS="|"
  printf '%s\n' "${ports[*]}"
}

show_unit_status() {
  local unit="${1:?unit is required}"
  systemctl --no-pager --lines=0 status "$unit" || true
}

show_sender_journal() {
  if systemctl_is_activeish relay-cover-sender.service; then
    local since
    since="$(systemctl show relay-cover-sender.service -p ActiveEnterTimestamp --value 2>/dev/null || true)"
    if [[ -n "$since" && "$since" != "n/a" ]]; then
      journalctl -u relay-cover-sender.service --since "$since" -n 80 --no-pager || true
      return 0
    fi
  fi

  journalctl -u relay-cover-sender.service -n 80 --no-pager || true
}

show_iperf3_capabilities() {
  if ! command -v iperf3 >/dev/null 2>&1; then
    log "WARN" "iperf3 command not found"
    return 0
  fi

  iperf3 --version | head -n 1 || true
  if iperf3_supports_option "--bind-dev"; then
    log "INFO" "iperf3 supports --bind-dev"
  else
    log "WARN" "iperf3 does not support --bind-dev"
  fi

  if iperf3_supports_option "--dscp"; then
    log "INFO" "iperf3 supports --dscp"
  else
    log "WARN" "iperf3 does not support --dscp"
  fi

  if iperf3_supports_option "--fq-rate"; then
    log "INFO" "iperf3 supports --fq-rate"
  else
    log "WARN" "iperf3 does not support --fq-rate"
  fi
}

main() {
  require_root
  require_cmd systemctl journalctl ss grep ip

  if [[ -f "$ENV_FILE" ]]; then
    load_and_validate_relay_env "$ENV_FILE" 0
    collect_target_ports "$COVER_TARGETS"
    printf 'EGRESS_DEV=%s\n' "$EGRESS_DEV"
    printf 'COVER_TARGETS=%s\n' "$COVER_TARGETS"
    printf 'COVER_RATE=%s (%sbps)\n' "$COVER_RATE" "$RELAY_COVER_RATE_BPS"
    printf 'COVER_DURATION_RANGE=%s\n' "$COVER_DURATION_RANGE"
    printf 'COVER_TYPE=%s\n' "$COVER_TYPE"
  else
    log "WARN" "relay runtime env not found: $ENV_FILE"
  fi

  show_unit_status relay-cover-sender.service
  show_unit_status relay-cover-sender.timer
  systemctl list-timers relay-cover-sender.timer --no-pager || true

  if [[ -n "${EGRESS_DEV:-}" ]]; then
    ip link show dev "$EGRESS_DEV" || true
  fi

  show_iperf3_capabilities

  if [[ "${#ports[@]}" -gt 0 ]]; then
    ss -tupn | grep -E ":($(port_regex))\\b" || true
  fi

  show_sender_journal
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
