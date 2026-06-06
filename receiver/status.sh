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
LEGACY_UNITS=(
  iperf3-dummy-receiver.service
  iperf3-dummy-receiver-v4.service
  iperf3-dummy-receiver-v6.service
)

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

systemctl status relay-cover-receiver-v4.service --no-pager || true
systemctl status relay-cover-receiver-v6.service --no-pager || true
systemctl cat relay-cover-receiver-v4.service 2>/dev/null | grep '^ExecStart=' || true
systemctl cat relay-cover-receiver-v6.service 2>/dev/null | grep '^ExecStart=' || true
ip -br addr 2>/dev/null | grep -vE '^(lo|warp|wg|tun|tailscale|docker|br-|virbr|veth)' || true
ss -tulpn | grep "$COVER_RECEIVER_PORT" || true

if command -v nft >/dev/null 2>&1; then
  nft list ruleset | grep "$COVER_RECEIVER_PORT" -C 3 || true
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

journalctl -u relay-cover-receiver-v4.service -n 50 --no-pager || true
journalctl -u relay-cover-receiver-v6.service -n 50 --no-pager || true

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
