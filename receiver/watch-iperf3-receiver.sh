#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/../common/lib.sh" ]]; then
  # shellcheck source=common/lib.sh
  source "$SCRIPT_DIR/../common/lib.sh"
elif [[ -r /usr/local/lib/relay-cover-traffic/lib.sh ]]; then
  # shellcheck source=common/lib.sh
  source /usr/local/lib/relay-cover-traffic/lib.sh
else
  echo "common library not found" >&2
  exit 1
fi

ENV_FILE="/etc/relay-cover-traffic/receiver.env"

socket_metrics() {
  local family_option="${1:?address family option is required}"
  local close_wait_count
  local listen_output
  local listener_count
  local receive_queue

  close_wait_count="$(
    ss -H -n -t "$family_option" state close-wait "sport = :${COVER_RECEIVER_PORT}" 2>/dev/null |
      awk 'NF { count += 1 } END { print count + 0 }'
  )"
  listen_output="$(ss -H -l -n -t "$family_option" "sport = :${COVER_RECEIVER_PORT}" 2>/dev/null || true)"
  listener_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<<"$listen_output")"
  receive_queue="$(awk 'NF { queue += $2 } END { print queue + 0 }' <<<"$listen_output")"

  printf '%s %s %s\n' "$close_wait_count" "$listener_count" "$receive_queue"
}

check_receiver_unit() {
  local unit="${1:?unit is required}"
  local family_name="${2:?address family name is required}"
  local family_option="${3:?address family option is required}"
  local first_close_wait
  local first_listener_count
  local first_receive_queue
  local second_close_wait
  local second_listener_count
  local second_receive_queue
  local restart_reason=""

  systemctl cat "$unit" >/dev/null 2>&1 || return 0

  if ! systemctl is-active --quiet "$unit"; then
    log "WARN" "$unit is not active; restarting it"
    systemctl restart "$unit"
    systemctl is-active --quiet "$unit" || die "$unit did not become active after watchdog restart"
    log "INFO" "$unit restarted successfully"
    return 0
  fi

  read -r first_close_wait first_listener_count first_receive_queue < <(socket_metrics "$family_option")
  if [[ "$first_listener_count" -gt 0 && "$first_close_wait" -lt "$COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD" ]]; then
    return 0
  fi

  sleep "$COVER_RECEIVER_STUCK_CONFIRM_SECONDS"
  read -r second_close_wait second_listener_count second_receive_queue < <(socket_metrics "$family_option")

  if [[ "$first_listener_count" -eq 0 && "$second_listener_count" -eq 0 ]]; then
    restart_reason="listener missing"
  elif [[ "$first_close_wait" -ge "$COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD" &&
          "$second_close_wait" -ge "$COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD" ]]; then
    restart_reason="persistent CLOSE-WAIT connections"
  fi

  if [[ -z "$restart_reason" ]]; then
    log "INFO" "$family_name receiver recovered without restart: close_wait=${first_close_wait}->${second_close_wait} recv_q=${first_receive_queue}->${second_receive_queue}"
    return 0
  fi

  log "WARN" "restarting $unit due to $restart_reason: close_wait=${first_close_wait}->${second_close_wait} recv_q=${first_receive_queue}->${second_receive_queue}"
  systemctl restart "$unit"

  if ! systemctl is-active --quiet "$unit"; then
    die "$unit did not become active after watchdog restart"
  fi

  log "INFO" "$unit restarted successfully"
}

require_root
require_cmd awk sleep ss systemctl
load_env_file "$ENV_FILE"
require_env COVER_RECEIVER_PORT

COVER_RECEIVER_WATCHDOG_ENABLED="${COVER_RECEIVER_WATCHDOG_ENABLED:-true}"
COVER_RECEIVER_STUCK_CONFIRM_SECONDS="${COVER_RECEIVER_STUCK_CONFIRM_SECONDS:-10}"
COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD="${COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD:-1}"

case "$COVER_RECEIVER_WATCHDOG_ENABLED" in
  true)
    ;;
  false)
    log "INFO" "receiver watchdog is disabled"
    exit 0
    ;;
  *)
    die "COVER_RECEIVER_WATCHDOG_ENABLED must be true or false"
    ;;
esac

validate_port "$COVER_RECEIVER_PORT" || die "invalid COVER_RECEIVER_PORT: $COVER_RECEIVER_PORT"
is_positive_int "$COVER_RECEIVER_STUCK_CONFIRM_SECONDS" || \
  die "COVER_RECEIVER_STUCK_CONFIRM_SECONDS must be a positive integer"
is_positive_int "$COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD" || \
  die "COVER_RECEIVER_STUCK_CONNECTION_THRESHOLD must be a positive integer"

check_receiver_unit relay-cover-receiver-v4.service IPv4 -4
check_receiver_unit relay-cover-receiver-v6.service IPv6 -6
