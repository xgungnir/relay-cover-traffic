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

load_env_file "$ENV_FILE"
require_env EGRESS_DEV RELAY_QOS_TARGETS COVER_TARGETS
COVER_TYPE="${COVER_TYPE:-auto}"
require_cmd systemctl tc ss journalctl grep tr

collect_target_ports "$RELAY_QOS_TARGETS"
collect_target_ports "$COVER_TARGETS"

printf 'RELAY_QOS_TARGETS=%s\n' "$RELAY_QOS_TARGETS"
printf 'COVER_TARGETS=%s\n' "$COVER_TARGETS"
printf 'COVER_TYPE=%s\n' "$COVER_TYPE"

systemctl status realm.service --no-pager || true
systemctl status relay-cover-qos.service --no-pager || true
systemctl status relay-cover-sender.service --no-pager || true
systemctl status relay-cover-sender.timer --no-pager || true
systemctl list-timers relay-cover-sender.timer --no-pager || true
tc -s qdisc show dev "$EGRESS_DEV" || true
tc -s class show dev "$EGRESS_DEV" || true
tc filter show dev "$EGRESS_DEV" parent 1: || true
ss -tupn | grep -E ":($(port_regex))\\b" || true
journalctl -u realm.service -n 80 --no-pager || true
journalctl -u relay-cover-qos.service -n 80 --no-pager || true
journalctl -u relay-cover-sender.service -n 80 --no-pager || true
