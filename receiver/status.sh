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

ENV_FILE="/etc/relay-cover-traffic/receiver.env"
ENV_SOURCE="$SCRIPT_DIR/../config/receiver.env"
NFT_TABLE="relay_cover_traffic"
LEGACY_UNITS=(
  iperf3-dummy-receiver.service
  iperf3-dummy-receiver-v4.service
  iperf3-dummy-receiver-v6.service
)

show_current_activation_journal() {
  local unit="${1:?unit is required}"
  local since=""

  since="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  if [[ -n "$since" && "$since" != "n/a" ]]; then
    journalctl -u "$unit" --since "$since" -n 50 --no-pager || true
  else
    journalctl -u "$unit" -n 50 --no-pager || true
  fi
}

unit_exists() {
  local unit="${1:?unit is required}"

  systemctl cat "$unit" >/dev/null 2>&1
}

show_receiver_unit_status() {
  local unit="${1:?unit is required}"
  local family="${2:?address family is required}"

  if unit_exists "$unit"; then
    systemctl status "$unit" --no-pager || true
    systemctl cat "$unit" 2>/dev/null | grep '^ExecStart=' || true
  elif [[ "$family" == "IPv6" ]]; then
    log "INFO" "$unit is not installed; no usable global IPv6 bind address may have been detected during receiver setup"
  else
    log "WARN" "$unit is not installed"
  fi
}

require_root
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env COVER_RECEIVER_PORT
require_cmd systemctl grep ip ss journalctl

for unit in "${LEGACY_UNITS[@]}"; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    log "WARN" "legacy receiver unit still exists: $unit"
  fi
done

show_receiver_unit_status relay-cover-receiver-v4.service IPv4
show_receiver_unit_status relay-cover-receiver-v6.service IPv6
ip -br addr 2>/dev/null | grep -vE '^(lo|warp|wg|tun|tailscale|docker|br-|virbr|veth)' || true
ss -tulpn | grep "$COVER_RECEIVER_PORT" || true

if command -v nft >/dev/null 2>&1; then
  nft list table inet "$NFT_TABLE" 2>/dev/null | grep "$COVER_RECEIVER_PORT" -C 3 || true
fi

if command -v iptables >/dev/null 2>&1; then
  log "INFO" "iptables version: $(iptables --version)"
  iptables -S INPUT | grep RELAY_COVER_TRAFFIC || true
  iptables -S RELAY_COVER_TRAFFIC 2>/dev/null || true
fi

if command -v ip6tables >/dev/null 2>&1; then
  log "INFO" "ip6tables version: $(ip6tables --version)"
  ip6tables -S INPUT | grep RELAY_COVER_TRAFFIC || true
  ip6tables -S RELAY_COVER_TRAFFIC 2>/dev/null || true
fi

if unit_exists relay-cover-receiver-v4.service; then
  show_current_activation_journal relay-cover-receiver-v4.service
fi
if unit_exists relay-cover-receiver-v6.service; then
  show_current_activation_journal relay-cover-receiver-v6.service
fi

if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'; then
  log "INFO" "sing-box package is installed"
else
  log "WARN" "sing-box package is not installed"
fi

if [[ -s /etc/sing-box/config.json ]]; then
  log "INFO" "/etc/sing-box/config.json exists and is non-empty"
else
  log "WARN" "/etc/sing-box/config.json is missing or empty"
fi
