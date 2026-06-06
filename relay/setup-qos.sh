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

ENV_FILE="/etc/relay-cover-traffic/relay.env"
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"
MAX_COVER_BPS=5000000
filter_prio=10

target_display() {
  local host="${1:?host is required}"
  local port="${2:?port is required}"

  if is_ipv6_literal "$host"; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

resolve_target_host() {
  local host="${1:?host is required}"
  local addr
  local key
  local seen="|"

  if is_ipv4_literal "$host"; then
    printf 'ip\t%s\n' "$host"
    return 0
  fi

  if is_ipv6_literal "$host"; then
    printf 'ipv6\t%s\n' "$host"
    return 0
  fi

  while IFS= read -r addr; do
    if is_ipv4_literal "$addr"; then
      key="ip:$addr|"
      [[ "$seen" == *"|$key"* ]] && continue
      seen="${seen}${key}"
      printf 'ip\t%s\n' "$addr"
    elif is_ipv6_literal "$addr"; then
      key="ipv6:$addr|"
      [[ "$seen" == *"|$key"* ]] && continue
      seen="${seen}${key}"
      printf 'ipv6\t%s\n' "$addr"
    fi
  done < <(
    {
      getent ahosts "$host" || true
      getent hosts "$host" || true
    } 2>/dev/null | awk '{print $1}' | sort -u
  )
}

add_flower_filter() {
  local ip_protocol="${1:?ip protocol is required}"
  local dst_ip="${2:?destination ip is required}"
  local l4_protocol="${3:?l4 protocol is required}"
  local dst_port="${4:?destination port is required}"
  local classid="${5:?classid is required}"

  tc filter add dev "$EGRESS_DEV" protocol "$ip_protocol" parent 1: prio "$filter_prio" flower \
    ip_proto "$l4_protocol" \
    dst_ip "$dst_ip" \
    dst_port "$dst_port" \
    classid "$classid"
  filter_prio=$((filter_prio + 1))
}

apply_target_filters() {
  local raw_targets="${1:?target list is required}"
  local classid="${2:?classid is required}"
  local label="${3:?label is required}"
  local host
  local port
  local ip_protocol
  local dst_ip
  local resolved_count
  local filter_count=0

  parse_target_list "$raw_targets" >/dev/null

  while IFS=$'\t' read -r host port; do
    resolved_count=0
    while IFS=$'\t' read -r ip_protocol dst_ip; do
      resolved_count=$((resolved_count + 1))
      log "INFO" "classifying ${label} target $(target_display "$host" "$port") via ${dst_ip}:${port} as ${classid}"
      add_flower_filter "$ip_protocol" "$dst_ip" udp "$port" "$classid"
      add_flower_filter "$ip_protocol" "$dst_ip" tcp "$port" "$classid"
      filter_count=$((filter_count + 2))
    done < <(resolve_target_host "$host")

    [[ "$resolved_count" -gt 0 ]] || die "failed to resolve ${label} target host: $host"
  done < <(parse_target_list "$raw_targets")

  [[ "$filter_count" -gt 0 ]] || die "no tc filters were created for $label targets"
}

require_root
require_cmd ip tc getent awk sort tr
if [[ -f "$ENV_SOURCE" ]]; then
  sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
fi
load_env_file "$ENV_FILE"
require_env EGRESS_DEV RELAY_QOS_TARGETS COVER_TARGETS TC_TOTAL_RATE TC_RELAY_RATE TC_RELAY_CEIL TC_COVER_RATE TC_COVER_CEIL TC_DEFAULT_RATE TC_DEFAULT_CEIL
DEV="$EGRESS_DEV"

ip link show dev "$DEV" >/dev/null || die "network interface not found: $DEV"

cover_ceil_bps="$(rate_to_bps "$TC_COVER_CEIL")" || die "invalid TC_COVER_CEIL rate: $TC_COVER_CEIL"
if [[ "${ALLOW_COVER_RATE_ABOVE_5M:-false}" != "true" && "$cover_ceil_bps" -gt "$MAX_COVER_BPS" ]]; then
  log "WARN" "TC_COVER_CEIL=$TC_COVER_CEIL is above 5mbit; capping tc cover class ceil at 5mbit"
  TC_COVER_CEIL="5mbit"
fi

log "INFO" "removing existing root qdisc on $DEV if present"
tc qdisc del dev "$DEV" root 2>/dev/null || true

log "INFO" "applying HTB/fq_codel QoS on $DEV"
tc qdisc add dev "$DEV" root handle 1: htb default 30

tc class add dev "$DEV" parent 1: classid 1:1 htb \
  rate "$TC_TOTAL_RATE" ceil "$TC_TOTAL_RATE"

tc class add dev "$DEV" parent 1:1 classid 1:10 htb \
  rate "$TC_RELAY_RATE" ceil "$TC_RELAY_CEIL" prio 0

tc class add dev "$DEV" parent 1:1 classid 1:20 htb \
  rate "$TC_COVER_RATE" ceil "$TC_COVER_CEIL" prio 7

tc class add dev "$DEV" parent 1:1 classid 1:30 htb \
  rate "$TC_DEFAULT_RATE" ceil "$TC_DEFAULT_CEIL" prio 3

tc qdisc add dev "$DEV" parent 1:10 handle 10: fq_codel
tc qdisc add dev "$DEV" parent 1:20 handle 20: fq_codel
tc qdisc add dev "$DEV" parent 1:30 handle 30: fq_codel

apply_target_filters "$RELAY_QOS_TARGETS" "1:10" "relay"
apply_target_filters "$COVER_TARGETS" "1:20" "cover"

log "INFO" "tc QoS applied"
tc -s qdisc show dev "$DEV"
tc -s class show dev "$DEV"
