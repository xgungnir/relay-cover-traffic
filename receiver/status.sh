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

# shellcheck source=common/firewall.sh
source "$SCRIPT_DIR/../common/firewall.sh"

ENV_FILE="/etc/relay-cover-traffic/receiver.env"
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
load_env_file "$ENV_FILE"
require_env COVER_RECEIVER_PORT
require_cmd systemctl grep ip ss journalctl awk sort

for unit in "${LEGACY_UNITS[@]}"; do
  if systemctl cat "$unit" >/dev/null 2>&1; then
    log "WARN" "legacy receiver unit still exists: $unit"
  fi
done

show_receiver_unit_status relay-cover-receiver-v4.service IPv4
show_receiver_unit_status relay-cover-receiver-v6.service IPv6
if unit_exists relay-cover-receiver-watchdog.timer; then
  systemctl status relay-cover-receiver-watchdog.timer --no-pager || true
  systemctl status relay-cover-receiver-watchdog.service --no-pager || true
else
  log "INFO" "relay-cover-receiver-watchdog.timer is not installed"
fi
if unit_exists relay-cover-receiver-firewall-refresh.timer; then
  systemctl status relay-cover-receiver-firewall-refresh.timer --no-pager || true
  systemctl status relay-cover-receiver-firewall-refresh.service --no-pager || true
else
  log "INFO" "relay-cover-receiver-firewall-refresh.timer is not installed"
fi
ip -br addr 2>/dev/null | grep -vE '^(lo|warp|wg|tun|tailscale|docker|br-|virbr|veth)' || true
ss -tulpn | grep "$COVER_RECEIVER_PORT" || true
log "INFO" "receiver TCP socket state summary"
ss -H -n -t "sport = :${COVER_RECEIVER_PORT}" 2>/dev/null |
  awk '{ states[$1] += 1 } END { for (state in states) print state, states[state] }' |
  sort || true

installed_backend="$(read_firewall_backend)"
log "INFO" "installed backend: ${installed_backend:-not recorded}"
if command -v nft >/dev/null 2>&1; then
  nft list table inet "$NFT_TABLE" 2>/dev/null || true
fi
for cmd in iptables-legacy-save ip6tables-legacy-save; do
  if command -v "$cmd" >/dev/null 2>&1; then
    "$cmd" | awk '/^-A RELAY_COVER_TRAFFIC / || /^-A INPUT .* -j RELAY_COVER_TRAFFIC( |$)/'
  fi
done

if unit_exists relay-cover-receiver-v4.service; then
  show_current_activation_journal relay-cover-receiver-v4.service
fi
if unit_exists relay-cover-receiver-v6.service; then
  show_current_activation_journal relay-cover-receiver-v6.service
fi
if unit_exists relay-cover-receiver-watchdog.service; then
  journalctl -u relay-cover-receiver-watchdog.service -n 30 --no-pager || true
fi
if unit_exists relay-cover-receiver-firewall-refresh.service; then
  journalctl -u relay-cover-receiver-firewall-refresh.service -n 30 --no-pager || true
fi
