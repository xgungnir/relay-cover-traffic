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
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="$SING_BOX_CONFIG_DIR/config.json"
SING_BOX_DATA_DIR="/var/lib/sing-box"
ports=()

collect_target_ports() {
  local raw_targets="${1:?target list is required}"
  local _target_host
  local port

  parse_target_list "$raw_targets" >/dev/null
  while IFS=$'\t' read -r _target_host port; do
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

show_current_activation_journal() {
  local unit="${1:?unit is required}"
  local state=""
  local since=""

  state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  [[ "$state" == "active" || "$state" == "activating" ]] || return 0

  since="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  if [[ -n "$since" && "$since" != "n/a" ]]; then
    journalctl -u "$unit" --since "$since" -n 80 --no-pager || true
  else
    journalctl -u "$unit" -n 80 --no-pager || true
  fi
}

show_sing_box_version() {
  if command -v sing-box >/dev/null 2>&1; then
    sing-box version || true
  else
    log "WARN" "sing-box command not found"
  fi
}

show_sing_box_check() {
  if ! command -v sing-box >/dev/null 2>&1; then
    log "WARN" "cannot check sing-box config because sing-box command is not installed"
    return 0
  fi

  if [[ ! -s "$SING_BOX_CONFIG" ]]; then
    log "WARN" "$SING_BOX_CONFIG is missing or empty"
    return 0
  fi

  sing-box check -D "$SING_BOX_DATA_DIR" -C "$SING_BOX_CONFIG_DIR" || true
}

require_root
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env EGRESS_DEV RELAY_QOS_TARGETS COVER_TARGETS
COVER_TYPE="${COVER_TYPE:-auto}"
require_cmd systemctl tc ss journalctl grep tr

collect_target_ports "$RELAY_QOS_TARGETS"
collect_target_ports "$COVER_TARGETS"

printf 'RELAY_QOS_TARGETS=%s\n' "$RELAY_QOS_TARGETS"
printf 'COVER_TARGETS=%s\n' "$COVER_TARGETS"
printf 'COVER_TYPE=%s\n' "$COVER_TYPE"

show_unit_status sing-box.service
show_sing_box_version
show_sing_box_check
ss -tulpn | grep sing-box || true
show_unit_status relay-cover-qos.service
show_unit_status relay-cover-sender.service
show_unit_status relay-cover-sender.timer
systemctl list-timers relay-cover-sender.timer --no-pager || true
tc -s qdisc show dev "$EGRESS_DEV" || true
tc -s class show dev "$EGRESS_DEV" || true
tc filter show dev "$EGRESS_DEV" parent 1: || true
ss -tupn | grep -E ":($(port_regex))\\b" || true
show_current_activation_journal sing-box.service
show_current_activation_journal relay-cover-qos.service
show_current_activation_journal relay-cover-sender.service
