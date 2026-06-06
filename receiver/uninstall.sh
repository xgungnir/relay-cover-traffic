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
NFT_INCLUDE_FILE="/etc/nftables.d/relay-cover-traffic.nft"
NFT_CONFIG_FILE="/etc/nftables.conf"
NFT_TABLE="relay_cover_traffic"
LEGACY_NFT_INCLUDE_FILE="/etc/nftables.d/vps-relay-dummy.nft"
LEGACY_NFT_TABLE="vps_relay_dummy"
IPTABLES_CHAIN="RELAY_COVER_TRAFFIC"
LEGACY_IPTABLES_CHAIN="VPS_RELAY_DUMMY"
NFT_INCLUDE_MARKER_BEGIN="# relay-cover-traffic include begin"
NFT_INCLUDE_MARKER_END="# relay-cover-traffic include end"
PURGE="false"

remove_xtables_project_jumps() {
  local cmd="${1:?xtables command is required}"
  local chain="${2:?chain name is required}"
  local rule
  local -a args

  command -v "$cmd" >/dev/null 2>&1 || return 0

  while true; do
    rule="$(
      "$cmd" -S INPUT 2>/dev/null |
        awk -v chain="$chain" '
          $1 == "-A" && $2 == "INPUT" {
            for (i = 1; i <= NF; i++) {
              if ($i == "-j" && $(i + 1) == chain) {
                $1 = "-D"
                print
                exit
              }
            }
          }
        '
    )"
    [[ -n "$rule" ]] || break
    read -r -a args <<<"$rule"
    "$cmd" "${args[@]}"
  done
}

delete_xtables_chain() {
  local cmd="${1:?xtables command is required}"
  local chain="${2:?chain name is required}"

  remove_xtables_project_jumps "$cmd" "$chain"
  "$cmd" -F "$chain" 2>/dev/null || true
  "$cmd" -X "$chain" 2>/dev/null || true
}

remove_iptables_legacy_rules() {
  local mode
  local mode6

  mode="$(iptables_mode 2>/dev/null || true)"
  if [[ "$mode" == "legacy" ]]; then
    log "INFO" "removing project iptables legacy chains if present"
    delete_xtables_chain iptables "$IPTABLES_CHAIN"
    delete_xtables_chain iptables "$LEGACY_IPTABLES_CHAIN"
  else
    log "INFO" "skipping iptables cleanup because iptables is not in legacy mode"
  fi

  mode6="$(ip6tables_mode 2>/dev/null || true)"
  if [[ "$mode6" == "legacy" ]]; then
    log "INFO" "removing project ip6tables legacy chains if present"
    delete_xtables_chain ip6tables "$IPTABLES_CHAIN"
    delete_xtables_chain ip6tables "$LEGACY_IPTABLES_CHAIN"
  else
    log "INFO" "skipping ip6tables cleanup because ip6tables is not in legacy mode"
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    log "INFO" "saving iptables removal with netfilter-persistent"
    netfilter-persistent save
  fi
}

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
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true

if command -v nft >/dev/null 2>&1; then
  log "INFO" "deleting project nftables tables if present"
  nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  nft delete table inet "$LEGACY_NFT_TABLE" 2>/dev/null || true
fi
remove_project_nftables_include_marker

remove_iptables_legacy_rules

log "INFO" "removing receiver unit files and firewall include files"
rm -f \
  /etc/systemd/system/relay-cover-receiver.service \
  /etc/systemd/system/relay-cover-receiver-v4.service \
  /etc/systemd/system/relay-cover-receiver-v6.service \
  /etc/systemd/system/iperf3-dummy-receiver.service \
  /etc/systemd/system/iperf3-dummy-receiver-v4.service \
  /etc/systemd/system/iperf3-dummy-receiver-v6.service \
  "$NFT_INCLUDE_FILE" \
  "$LEGACY_NFT_INCLUDE_FILE"

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
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true
log "INFO" "receiver uninstall complete"
