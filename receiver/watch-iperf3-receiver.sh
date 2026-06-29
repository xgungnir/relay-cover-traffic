#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/relay-cover-traffic/receiver.env"
CONFIRM_SECONDS=10

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

close_wait_count() {
  local family_option="${1:?address family option is required}"

  ss -H -n -t "$family_option" state close-wait "sport = :${COVER_RECEIVER_PORT}" 2>/dev/null |
    awk 'NF { count += 1 } END { print count + 0 }'
}

check_receiver() {
  local unit="${1:?unit is required}"
  local family_option="${2:?address family option is required}"
  local first_count
  local second_count

  systemctl cat "$unit" >/dev/null 2>&1 || return 0

  if ! systemctl is-active --quiet "$unit"; then
    log "$unit is inactive; restarting"
    systemctl restart "$unit"
    return 0
  fi

  first_count="$(close_wait_count "$family_option")"
  [[ "$first_count" -gt 0 ]] || return 0

  sleep "$CONFIRM_SECONDS"
  second_count="$(close_wait_count "$family_option")"
  [[ "$second_count" -gt 0 ]] || return 0

  log "$unit has persistent CLOSE-WAIT connections (${first_count}->${second_count}); restarting"
  systemctl restart "$unit"
}

[[ -r "$ENV_FILE" ]] || {
  log "receiver env not found: $ENV_FILE"
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "${COVER_RECEIVER_PORT:-}" =~ ^[1-9][0-9]*$ ]] || {
  log "invalid COVER_RECEIVER_PORT"
  exit 1
}

check_receiver relay-cover-receiver-v4.service -4
check_receiver relay-cover-receiver-v6.service -6
