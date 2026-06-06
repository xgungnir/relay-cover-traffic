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
NFT_INCLUDE_DIR="/etc/nftables.d"
NFT_INCLUDE_FILE="$NFT_INCLUDE_DIR/relay-cover-traffic.nft"
NFT_TABLE="relay_cover_traffic"
LEGACY_NFT_INCLUDE_FILE="$NFT_INCLUDE_DIR/vps-relay-dummy.nft"
LEGACY_NFT_TABLE="vps_relay_dummy"
IPTABLES_CHAIN="RELAY_COVER_TRAFFIC"
LEGACY_IPTABLES_CHAIN="VPS_RELAY_DUMMY"
COVER_SOURCE_WHITELIST_V4_ENTRIES=()
COVER_SOURCE_WHITELIST_V6_ENTRIES=()

normalize_firewall_backend() {
  local backend="${1:?firewall backend is required}"
  local mode

  case "$backend" in
    nftables)
      printf '%s\n' "nftables"
      ;;
    iptables | iptables-legacy | iptables_legacy | legacy)
      require_iptables_legacy
      printf '%s\n' "iptables-legacy"
      ;;
    auto)
      mode="$(iptables_mode 2>/dev/null || true)"
      if [[ "$mode" == "legacy" ]]; then
        printf '%s\n' "iptables-legacy"
      else
        require_cmd nft
        printf '%s\n' "nftables"
      fi
      ;;
    *)
      die "unsupported FIREWALL_BACKEND=$backend. Supported values: nftables, iptables-legacy, auto"
      ;;
  esac
}

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

parse_whitelist() {
  local raw="${1:-}"
  local family="${2:?address family is required}"
  local -n out="$3"
  local entry
  local normalized

  normalized="${raw//,/ }"
  out=()

  for entry in $normalized; do
    case "$family" in
      ipv4)
        [[ "$entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || die "invalid IPv4 whitelist entry: $entry"
        ;;
      ipv6)
        [[ "$entry" == *:* ]] || die "invalid IPv6 whitelist entry: $entry"
        [[ "$entry" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "invalid IPv6 whitelist entry: $entry"
        ;;
      *)
        die "internal error: unsupported whitelist family $family"
        ;;
    esac
    out+=("$entry")
  done
}

load_whitelists() {
  parse_whitelist "${COVER_SOURCE_WHITELIST_V4:-}" ipv4 COVER_SOURCE_WHITELIST_V4_ENTRIES
  parse_whitelist "${COVER_SOURCE_WHITELIST_V6:-}" ipv6 COVER_SOURCE_WHITELIST_V6_ENTRIES

  if [[ "${#COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}" -eq 0 && "${#COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}" -eq 0 ]]; then
    die "set at least one COVER_SOURCE_WHITELIST_V4 or COVER_SOURCE_WHITELIST_V6 entry"
  fi
}

delete_nftables_project_rules() {
  if command -v nft >/dev/null 2>&1; then
    log "INFO" "deleting project nftables tables if present"
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    nft delete table inet "$LEGACY_NFT_TABLE" 2>/dev/null || true
  fi

  rm -f "$NFT_INCLUDE_FILE" "$LEGACY_NFT_INCLUDE_FILE"
}

delete_iptables_legacy_project_rules() {
  local mode
  local mode6

  mode="$(iptables_mode 2>/dev/null || true)"
  if [[ "$mode" == "legacy" ]]; then
    log "INFO" "deleting project iptables legacy chains if present"
    delete_xtables_chain iptables "$IPTABLES_CHAIN"
    delete_xtables_chain iptables "$LEGACY_IPTABLES_CHAIN"
  fi

  mode6="$(ip6tables_mode 2>/dev/null || true)"
  if [[ "$mode6" == "legacy" ]]; then
    log "INFO" "deleting project ip6tables legacy chains if present"
    delete_xtables_chain ip6tables "$IPTABLES_CHAIN"
    delete_xtables_chain ip6tables "$LEGACY_IPTABLES_CHAIN"
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  fi
}

apply_nftables_rules() {
  local entry

  require_cmd nft systemctl install awk grep chmod
  delete_iptables_legacy_project_rules
  delete_nftables_project_rules

  log "INFO" "enabling nftables service"
  systemctl enable --now nftables

  install -d -m 0755 "$NFT_INCLUDE_DIR"

  log "INFO" "writing project nftables include file to $NFT_INCLUDE_FILE"
  {
    cat <<NFT
table inet ${NFT_TABLE} {
  chain input {
    type filter hook input priority -10; policy accept;

NFT
    for entry in "${COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}"; do
      printf '    ip saddr %s tcp dport %s accept\n' "$entry" "$COVER_RECEIVER_PORT"
      printf '    ip saddr %s udp dport %s accept\n' "$entry" "$COVER_RECEIVER_PORT"
    done
    for entry in "${COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}"; do
      printf '    ip6 saddr %s tcp dport %s accept\n' "$entry" "$COVER_RECEIVER_PORT"
      printf '    ip6 saddr %s udp dport %s accept\n' "$entry" "$COVER_RECEIVER_PORT"
    done
    cat <<NFT
    tcp dport ${COVER_RECEIVER_PORT} drop
    udp dport ${COVER_RECEIVER_PORT} drop
  }
}
NFT
  } >"$NFT_INCLUDE_FILE"
  chmod 0644 "$NFT_INCLUDE_FILE"

  log "INFO" "applying only table inet $NFT_TABLE"
  nft -f "$NFT_INCLUDE_FILE"

  if ! grep -Eq '^[[:space:]]*include[[:space:]]+"/etc/nftables\.d/\*\.nft"' /etc/nftables.conf 2>/dev/null; then
    log "WARN" "$NFT_INCLUDE_FILE was applied now, but /etc/nftables.conf does not include /etc/nftables.d/*.nft"
    log "WARN" "Add this line to /etc/nftables.conf if you want this project nftables table loaded by nftables.service after reboot:"
    log "WARN" 'include "/etc/nftables.d/*.nft"'
  fi

  log "INFO" "project nftables rules applied"
  log "WARN" "If another nftables base chain already uses default-deny input policy, also integrate explicit allows for COVER_SOURCE_WHITELIST_V4/COVER_SOURCE_WHITELIST_V6 and COVER_RECEIVER_PORT=$COVER_RECEIVER_PORT in that policy."
}

apply_iptables_legacy_rules() {
  local entry
  local manage_ipv6="false"

  require_cmd awk
  require_iptables_legacy
  if [[ "${#COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}" -gt 0 ]]; then
    require_ip6tables_legacy
    manage_ipv6="true"
  elif [[ "$(ip6tables_mode 2>/dev/null || true)" == "legacy" ]]; then
    manage_ipv6="true"
  else
    log "WARN" "no ip6tables legacy rules will be applied because COVER_SOURCE_WHITELIST_V6 is empty and ip6tables is not in legacy mode"
  fi

  delete_nftables_project_rules
  delete_iptables_legacy_project_rules

  log "INFO" "using iptables legacy backend: $(iptables --version)"
  log "INFO" "recreating project iptables chain $IPTABLES_CHAIN"

  iptables -N "$IPTABLES_CHAIN"
  for entry in "${COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}"; do
    iptables -A "$IPTABLES_CHAIN" -s "$entry" -p tcp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
    iptables -A "$IPTABLES_CHAIN" -s "$entry" -p udp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
  done
  iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$COVER_RECEIVER_PORT" -j DROP
  iptables -A "$IPTABLES_CHAIN" -p udp --dport "$COVER_RECEIVER_PORT" -j DROP
  iptables -A "$IPTABLES_CHAIN" -j RETURN

  iptables -I INPUT 1 -p udp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
  iptables -I INPUT 1 -p tcp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"

  if [[ "$manage_ipv6" == "true" ]]; then
    log "INFO" "using ip6tables legacy backend: $(ip6tables --version)"
    log "INFO" "recreating project ip6tables chain $IPTABLES_CHAIN"

    ip6tables -N "$IPTABLES_CHAIN"
    for entry in "${COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}"; do
      ip6tables -A "$IPTABLES_CHAIN" -s "$entry" -p tcp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
      ip6tables -A "$IPTABLES_CHAIN" -s "$entry" -p udp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
    done
    ip6tables -A "$IPTABLES_CHAIN" -p tcp --dport "$COVER_RECEIVER_PORT" -j DROP
    ip6tables -A "$IPTABLES_CHAIN" -p udp --dport "$COVER_RECEIVER_PORT" -j DROP
    ip6tables -A "$IPTABLES_CHAIN" -j RETURN

    ip6tables -I INPUT 1 -p udp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
    ip6tables -I INPUT 1 -p tcp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    log "INFO" "saving iptables legacy rules with netfilter-persistent"
    netfilter-persistent save
  else
    log "WARN" "iptables legacy rules were applied now, but netfilter-persistent is not installed; install iptables-persistent or otherwise persist these rules before reboot."
  fi

  log "INFO" "project iptables legacy rules applied"
}

require_root
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env COVER_RECEIVER_PORT FIREWALL_BACKEND
validate_port "$COVER_RECEIVER_PORT" || die "invalid COVER_RECEIVER_PORT: $COVER_RECEIVER_PORT"
load_whitelists

BACKEND="$(normalize_firewall_backend "$FIREWALL_BACKEND")"
log "INFO" "selected firewall backend: $BACKEND"
log "INFO" "IPv4 cover source whitelist entries: ${#COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}"
log "INFO" "IPv6 cover source whitelist entries: ${#COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}"

case "$BACKEND" in
  nftables) apply_nftables_rules ;;
  iptables-legacy) apply_iptables_legacy_rules ;;
  *) die "internal error: unexpected backend $BACKEND" ;;
esac
