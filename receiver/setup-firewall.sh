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
ENV_SOURCE="$SCRIPT_DIR/../config/receiver.env"
NFT_INCLUDE_DIR="/etc/nftables.d"
NFT_TABLE="relay_cover_traffic"
IPTABLES_CHAIN="RELAY_COVER_TRAFFIC"
FIREWALL_REFRESH_SERVICE_FILE="/etc/systemd/system/relay-cover-receiver-firewall-refresh.service"
FIREWALL_REFRESH_TIMER_FILE="/etc/systemd/system/relay-cover-receiver-firewall-refresh.timer"
COVER_SOURCE_WHITELIST_V4_ENTRIES=()
COVER_SOURCE_WHITELIST_V6_ENTRIES=()

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

write_firewall_refresh_units() {
  [[ "${RELAY_FIREWALL_REFRESH_SKIP_UNIT_INSTALL:-0}" != "1" ]] || return 0

  require_cmd systemctl chmod

  log "INFO" "writing receiver firewall refresh service: $FIREWALL_REFRESH_SERVICE_FILE"
  cat >"$FIREWALL_REFRESH_SERVICE_FILE" <<UNIT
[Unit]
Description=Refresh relay cover receiver firewall whitelist
After=network-online.target nftables.service netfilter-persistent.service
Wants=network-online.target
Before=relay-cover-receiver-v4.service relay-cover-receiver-v6.service

[Service]
Type=oneshot
ExecStart=/usr/bin/env RELAY_FIREWALL_REFRESH_SKIP_UNIT_INSTALL=1 ${SCRIPT_DIR}/setup-firewall.sh

[Install]
WantedBy=multi-user.target
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
  systemctl enable relay-cover-receiver-firewall-refresh.service
  systemctl enable --now relay-cover-receiver-firewall-refresh.timer
}

apply_nftables_rules() (
  local entry candidate
  require_cmd nft install mktemp chmod
  install -d -m 0755 "$NFT_INCLUDE_DIR"
  candidate="$(mktemp "$NFT_INCLUDE_DIR/.receiver-rules.XXXXXX")"
  trap 'rm -f "$candidate"' EXIT
  {
    if nft list table inet "$NFT_TABLE" >/dev/null 2>&1; then
      printf 'delete table inet %s\n' "$NFT_TABLE"
    fi
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
  } >"$candidate"
  nft -c -f "$candidate" || return 1
  # Delete/recreate is a single nft transaction; a failed update keeps old rules.
  nft -f "$candidate" || return 1
  log "INFO" "applied project nftables table atomically; global nftables service/config unchanged"
  log "WARN" "Other firewall chains can still block allowed receiver traffic; integrate allows into existing default-deny policies."
)

apply_iptables_legacy_rules() {
  local entry
  local cmd
  require_cmd iptables-legacy ip6tables-legacy
  for cmd in iptables-legacy ip6tables-legacy; do
    remove_xtables_project_chain "$cmd" "$IPTABLES_CHAIN"
  done

  log "INFO" "recreating project iptables chain $IPTABLES_CHAIN"

  iptables-legacy -w 5 -N "$IPTABLES_CHAIN"
  for entry in "${COVER_SOURCE_WHITELIST_V4_ENTRIES[@]}"; do
    iptables-legacy -w 5 -A "$IPTABLES_CHAIN" -s "$entry" -p tcp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
    iptables-legacy -w 5 -A "$IPTABLES_CHAIN" -s "$entry" -p udp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
  done
  iptables-legacy -w 5 -A "$IPTABLES_CHAIN" -p tcp --dport "$COVER_RECEIVER_PORT" -j DROP
  iptables-legacy -w 5 -A "$IPTABLES_CHAIN" -p udp --dport "$COVER_RECEIVER_PORT" -j DROP
  iptables-legacy -w 5 -A "$IPTABLES_CHAIN" -j RETURN

  iptables-legacy -w 5 -I INPUT 1 -p udp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
  iptables-legacy -w 5 -I INPUT 1 -p tcp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"

  {
    log "INFO" "using explicit ip6tables-legacy backend"
    log "INFO" "recreating project ip6tables chain $IPTABLES_CHAIN"

    ip6tables-legacy -w 5 -N "$IPTABLES_CHAIN"
    for entry in "${COVER_SOURCE_WHITELIST_V6_ENTRIES[@]}"; do
      ip6tables-legacy -w 5 -A "$IPTABLES_CHAIN" -s "$entry" -p tcp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
      ip6tables-legacy -w 5 -A "$IPTABLES_CHAIN" -s "$entry" -p udp --dport "$COVER_RECEIVER_PORT" -j ACCEPT
    done
    ip6tables-legacy -w 5 -A "$IPTABLES_CHAIN" -p tcp --dport "$COVER_RECEIVER_PORT" -j DROP
    ip6tables-legacy -w 5 -A "$IPTABLES_CHAIN" -p udp --dport "$COVER_RECEIVER_PORT" -j DROP
    ip6tables-legacy -w 5 -A "$IPTABLES_CHAIN" -j RETURN

    ip6tables-legacy -w 5 -I INPUT 1 -p udp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
    ip6tables-legacy -w 5 -I INPUT 1 -p tcp --dport "$COVER_RECEIVER_PORT" -j "$IPTABLES_CHAIN"
  }

  log "INFO" "project iptables legacy rules applied"
}

if [[ "${RELAY_SETUP_FIREWALL_SOURCE_ONLY:-0}" == "1" ]]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

require_root
require_cmd flock
exec 9>/run/lock/relay-cover-receiver-firewall.lock
flock -w 30 9 || die "receiver firewall operation is busy"
load_env_file "$ENV_SOURCE"
require_env COVER_RECEIVER_PORT
validate_port "$COVER_RECEIVER_PORT" || die "invalid COVER_RECEIVER_PORT: $COVER_RECEIVER_PORT"
load_whitelists

BACKEND="$(select_firewall_backend)"
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

install -d -m 0700 "${FIREWALL_BACKEND_FILE%/*}"
printf '%s\n' "$BACKEND" >"${FIREWALL_BACKEND_FILE}.tmp"
chmod 0600 "${FIREWALL_BACKEND_FILE}.tmp"
mv -f "${FIREWALL_BACKEND_FILE}.tmp" "$FIREWALL_BACKEND_FILE"
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
write_firewall_refresh_units
