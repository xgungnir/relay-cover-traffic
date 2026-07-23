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
NFT_CONFIG_FILE="/etc/nftables.conf"
NFT_TABLE="relay_cover_traffic"
LEGACY_NFT_INCLUDE_FILE="$NFT_INCLUDE_DIR/vps-relay-dummy.nft"
LEGACY_NFT_TABLE="vps_relay_dummy"
IPTABLES_CHAIN="RELAY_COVER_TRAFFIC"
LEGACY_IPTABLES_CHAIN="VPS_RELAY_DUMMY"
FIREWALL_REFRESH_SERVICE_FILE="/etc/systemd/system/relay-cover-receiver-firewall-refresh.service"
FIREWALL_REFRESH_TIMER_FILE="/etc/systemd/system/relay-cover-receiver-firewall-refresh.timer"
NFT_INCLUDE_MARKER_BEGIN="# relay-cover-traffic include begin"
NFT_INCLUDE_MARKER_END="# relay-cover-traffic include end"
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
  local out_name="${3:?output array name is required}"
  local entry
  local normalized
  local resolved
  local resolved_output
  local -a parsed_entries=()

  normalized="${raw//,/ }"

  for entry in $normalized; do
    case "$family" in
      ipv4)
        if is_ipv4_or_cidr "$entry"; then
          add_unique_parsed_whitelist_entry "$entry"
          continue
        fi
        is_dns_name "$entry" || die "invalid IPv4 whitelist entry: $entry"
        resolved_output="$(resolve_whitelist_name "$entry" ipv4)"
        while IFS= read -r resolved; do
          [[ -n "$resolved" ]] || continue
          add_unique_parsed_whitelist_entry "$resolved"
        done <<<"$resolved_output"
        ;;
      ipv6)
        if is_ipv6_or_cidr "$entry"; then
          add_unique_parsed_whitelist_entry "$entry"
          continue
        fi
        is_dns_name "$entry" || die "invalid IPv6 whitelist entry: $entry"
        resolved_output="$(resolve_whitelist_name "$entry" ipv6)"
        while IFS= read -r resolved; do
          [[ -n "$resolved" ]] || continue
          add_unique_parsed_whitelist_entry "$resolved"
        done <<<"$resolved_output"
        ;;
      *)
        die "internal error: unsupported whitelist family $family"
        ;;
    esac
  done

  eval "$out_name=()"
  for entry in "${parsed_entries[@]+"${parsed_entries[@]}"}"; do
    eval "$out_name+=(\"\$entry\")"
  done
}

add_unique_parsed_whitelist_entry() {
  local entry="${1:?entry is required}"
  local existing

  for existing in "${parsed_entries[@]+"${parsed_entries[@]}"}"; do
    [[ "$existing" == "$entry" ]] && return 0
  done

  parsed_entries+=("$entry")
}

is_ipv4_or_cidr() {
  local entry="${1:-}"
  local ip="${entry%%/*}"
  local prefix=""

  if [[ "$entry" == */* ]]; then
    prefix="${entry#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((10#$prefix <= 32)) || return 1
  fi

  is_ipv4_literal "$ip"
}

is_ipv6_or_cidr() {
  local entry="${1:-}"
  local ip="${entry%%/*}"
  local prefix=""

  if [[ "$entry" == */* ]]; then
    prefix="${entry#*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    ((10#$prefix <= 128)) || return 1
  fi

  is_ipv6_literal "$ip"
}

is_dns_name() {
  local name="${1:-}"
  local label
  local -a labels

  [[ ${#name} -le 253 ]] || return 1
  [[ "$name" == *.* ]] || return 1
  [[ "$name" != *..* ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]] || return 1

  IFS=. read -r -a labels <<<"$name"
  for label in "${labels[@]}"; do
    [[ -n "$label" && ${#label} -le 63 ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

resolve_whitelist_name() {
  local name="${1:?DNS name is required}"
  local family="${2:?address family is required}"
  local getent_db
  local address
  local -a resolved=()

  require_cmd getent sort

  case "$family" in
    ipv4) getent_db="ahostsv4" ;;
    ipv6) getent_db="ahostsv6" ;;
    *) die "internal error: unsupported resolver family $family" ;;
  esac

  while read -r address _; do
    case "$family" in
      ipv4)
        is_ipv4_literal "$address" || continue
        ;;
      ipv6)
        is_ipv6_literal "$address" || continue
        ;;
    esac
    resolved+=("$address")
  done < <(getent "$getent_db" "$name" 2>/dev/null | sort -u)

  [[ "${#resolved[@]}" -gt 0 ]] || die "DNS name $name did not resolve any $family whitelist address"
  log "INFO" "resolved $family whitelist name $name to: ${resolved[*]}"
  printf '%s\n' "${resolved[@]}"
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
  local save_persistent="${1:-true}"
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

  if [[ "$save_persistent" == "true" ]] && command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  fi
}

ensure_nftables_config_include() {
  require_cmd grep

  if [[ ! -f "$NFT_CONFIG_FILE" ]]; then
    log "INFO" "creating $NFT_CONFIG_FILE with project include"
    {
      printf '%s\n' '#!/usr/sbin/nft -f'
      printf '%s\n\n' 'flush ruleset'
      printf '%s\n' "$NFT_INCLUDE_MARKER_BEGIN"
      printf '%s\n' 'include "/etc/nftables.d/*.nft"'
      printf '%s\n' "$NFT_INCLUDE_MARKER_END"
    } >"$NFT_CONFIG_FILE"
    chmod 0644 "$NFT_CONFIG_FILE"
    return 0
  fi

  if grep -Eq '^[[:space:]]*include[[:space:]]+"/etc/nftables\.d/\*\.nft"' "$NFT_CONFIG_FILE"; then
    log "INFO" "$NFT_CONFIG_FILE already includes /etc/nftables.d/*.nft"
    return 0
  fi

  log "INFO" "adding project nftables include marker to $NFT_CONFIG_FILE"
  {
    printf '\n%s\n' "$NFT_INCLUDE_MARKER_BEGIN"
    printf '%s\n' 'include "/etc/nftables.d/*.nft"'
    printf '%s\n' "$NFT_INCLUDE_MARKER_END"
  } >>"$NFT_CONFIG_FILE"
}

netfilter_persistent_has_iptables_plugins() {
  command -v netfilter-persistent >/dev/null 2>&1 &&
    [[ -e /usr/share/netfilter-persistent/plugins.d/15-ip4tables ]] &&
    [[ -e /usr/share/netfilter-persistent/plugins.d/25-ip6tables ]]
}

ensure_iptables_persistent() {
  if netfilter_persistent_has_iptables_plugins; then
    log "INFO" "netfilter-persistent iptables/ip6tables plugins already installed"
  else
    require_cmd apt-get
    export DEBIAN_FRONTEND=noninteractive
    log "INFO" "installing netfilter-persistent and iptables-persistent for IPv4/IPv6 rule persistence"
    apt-get update
    apt_get_install netfilter-persistent iptables-persistent
  fi

  netfilter_persistent_has_iptables_plugins || die "netfilter-persistent iptables/ip6tables plugins are missing after install"
  systemctl enable netfilter-persistent.service >/dev/null 2>&1 || true
}

save_iptables_legacy_rules() {
  ensure_iptables_persistent
  log "INFO" "saving IPv4 and IPv6 iptables legacy rules with netfilter-persistent"
  netfilter-persistent save
}

write_firewall_refresh_units() {
  [[ "${RELAY_FIREWALL_REFRESH_SKIP_UNIT_INSTALL:-0}" != "1" ]] || return 0

  require_cmd systemctl chmod

  log "INFO" "writing receiver firewall refresh service: $FIREWALL_REFRESH_SERVICE_FILE"
  cat >"$FIREWALL_REFRESH_SERVICE_FILE" <<UNIT
[Unit]
Description=Refresh relay cover receiver firewall whitelist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env RELAY_FIREWALL_REFRESH_SKIP_UNIT_INSTALL=1 ${SCRIPT_DIR}/setup-firewall.sh
UNIT

  log "INFO" "writing receiver firewall refresh timer: $FIREWALL_REFRESH_TIMER_FILE"
  cat >"$FIREWALL_REFRESH_TIMER_FILE" <<UNIT
[Unit]
Description=Refresh relay cover receiver firewall whitelist every 30 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
RandomizedDelaySec=2min
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  chmod 0644 "$FIREWALL_REFRESH_SERVICE_FILE" "$FIREWALL_REFRESH_TIMER_FILE"
  systemctl daemon-reload
  systemctl enable --now relay-cover-receiver-firewall-refresh.timer
}

apply_nftables_rules() {
  local entry

  require_cmd nft systemctl install awk grep chmod
  delete_iptables_legacy_project_rules
  delete_nftables_project_rules

  log "INFO" "enabling nftables service"
  systemctl enable --now nftables

  install -d -m 0755 "$NFT_INCLUDE_DIR"
  ensure_nftables_config_include

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
  delete_iptables_legacy_project_rules false

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

  save_iptables_legacy_rules

  log "INFO" "project iptables legacy rules applied"
}

if [[ "${RELAY_SETUP_FIREWALL_SOURCE_ONLY:-0}" == "1" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

require_root
load_env_file "$ENV_SOURCE"
require_env COVER_RECEIVER_PORT FIREWALL_BACKEND
validate_port "$COVER_RECEIVER_PORT" || die "invalid COVER_RECEIVER_PORT: $COVER_RECEIVER_PORT"
load_whitelists

BACKEND="$(normalize_firewall_backend "$FIREWALL_BACKEND")"
log "INFO" "selected firewall backend: $BACKEND"
log "INFO" "IPv4 cover source whitelist entries: ${#COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}"
log "INFO" "IPv6 cover source whitelist entries: ${#COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}"
if [[ "${#COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}" -gt 0 ]]; then
  log "INFO" "IPv6 firewall rules will be applied even if relay-cover-receiver-v6.service is not installed yet"
fi

case "$BACKEND" in
  nftables) apply_nftables_rules ;;
  iptables-legacy) apply_iptables_legacy_rules ;;
  *) die "internal error: unexpected backend $BACKEND" ;;
esac

sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
write_firewall_refresh_units
