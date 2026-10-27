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
NFT_INCLUDE_FILE="/etc/nftables.d/relay-cover-traffic.nft"
NFT_CONFIG_FILE="/etc/nftables.conf"
LEGACY_NFT_INCLUDE_FILE="/etc/nftables.d/vps-relay-dummy.nft"
NFT_INCLUDE_MARKER_BEGIN="# relay-cover-traffic include begin"
NFT_INCLUDE_MARKER_END="# relay-cover-traffic include end"
PURGE="false"

remove_project_nftables_include_marker() {
  [[ -f "$NFT_CONFIG_FILE" ]] || return 0
  grep -Fq "$NFT_INCLUDE_MARKER_BEGIN" "$NFT_CONFIG_FILE" || return 0

  log "INFO" "removing project nftables include marker from $NFT_CONFIG_FILE"
  sed -i "/^${NFT_INCLUDE_MARKER_BEGIN}$/,/^${NFT_INCLUDE_MARKER_END}$/d" "$NFT_CONFIG_FILE"
}

case "${1:-}" in
  "")
    ;;
  --purge)
    PURGE="true"
    ;;
  *)
    die "usage: $0 [--purge]"
    ;;
esac

require_root
require_cmd systemctl rm awk grep sed

if [[ -f "$ENV_FILE" ]]; then
  log "INFO" "using receiver env path: $ENV_FILE"
else
  log "WARN" "$ENV_FILE not found; continuing best-effort uninstall"
fi

log "INFO" "disabling receiver systemd units"
systemctl disable --now \
  relay-cover-receiver.service \
  relay-cover-receiver-v4.service \
  relay-cover-receiver-v6.service \
  relay-cover-receiver-firewall-refresh.service \
  relay-cover-receiver-firewall-refresh.timer \
  relay-cover-receiver-watchdog.service \
  relay-cover-receiver-watchdog.timer \
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true

require_cmd flock
exec 9>/run/lock/relay-cover-receiver-firewall.lock
flock -w 30 9 || die "receiver firewall operation is busy"
remove_receiver_firewall_rules
remove_project_nftables_include_marker
rm -f "$FIREWALL_BACKEND_FILE"

log "INFO" "removing receiver unit files and firewall include files"
rm -f \
  /etc/systemd/system/relay-cover-receiver.service \
  /etc/systemd/system/relay-cover-receiver-v4.service \
  /etc/systemd/system/relay-cover-receiver-v6.service \
  /etc/systemd/system/relay-cover-receiver-firewall-refresh.service \
  /etc/systemd/system/relay-cover-receiver-firewall-refresh.timer \
  /etc/systemd/system/relay-cover-receiver-watchdog.service \
  /etc/systemd/system/relay-cover-receiver-watchdog.timer \
  /etc/systemd/system/iperf3-dummy-receiver.service \
  /etc/systemd/system/iperf3-dummy-receiver-v4.service \
  /etc/systemd/system/iperf3-dummy-receiver-v6.service \
  "$NFT_INCLUDE_FILE" \
  "$LEGACY_NFT_INCLUDE_FILE"

rm -f /usr/local/sbin/relay-cover-receiver-watchdog.sh

if [[ "$PURGE" == "true" ]]; then
  log "WARN" "purging $ENV_FILE"
  rm -f "$ENV_FILE"
  rmdir /etc/relay-cover-traffic 2>/dev/null || true
else
  log "INFO" "preserving $ENV_FILE"
fi

systemctl daemon-reload
systemctl reset-failed \
  relay-cover-receiver.service \
  relay-cover-receiver-v4.service \
  relay-cover-receiver-v6.service \
  relay-cover-receiver-firewall-refresh.service \
  relay-cover-receiver-firewall-refresh.timer \
  relay-cover-receiver-watchdog.service \
  relay-cover-receiver-watchdog.timer \
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true
log "INFO" "receiver uninstall complete"
