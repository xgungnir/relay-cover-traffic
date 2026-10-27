#!/usr/bin/env bash
# Shared receiver backend selection and project-only rule cleanup.

FIREWALL_BACKEND_FILE="${FIREWALL_BACKEND_FILE:-/etc/relay-cover-traffic/firewall.backend}"

read_firewall_backend() {
  local backend
  [[ -f "$FIREWALL_BACKEND_FILE" ]] || return 0
  backend="$(cat "$FIREWALL_BACKEND_FILE")"
  case "$backend" in
    nftables|iptables-legacy) printf '%s\n' "$backend" ;;
    *) die "invalid backend record: $FIREWALL_BACKEND_FILE" ;;
  esac
}

inspect_firewall_backends() {
  local rules cmd
  FIREWALL_NFT_AVAILABLE=0
  FIREWALL_NFT_RULES=0
  FIREWALL_LEGACY_AVAILABLE=0
  FIREWALL_LEGACY_RULES=0

  if command -v nft >/dev/null 2>&1; then
    require_cmd jq
    rules="$(nft -j list ruleset)" || die "cannot inspect nftables rules; refusing to guess backend"
    jq -e '.nftables | type == "array"' <<<"$rules" >/dev/null || die "invalid nftables inspection output"
    FIREWALL_NFT_AVAILABLE=1
    if jq -e '[.nftables[] | (.rule // .chain // empty) |
      select((.table != "relay_cover_traffic" and .table != "vps_relay_dummy") or .family != "inet") |
      select(has("expr") or (.policy? == "drop"))] | length > 0' <<<"$rules" >/dev/null; then
      FIREWALL_NFT_RULES=1
    fi
  fi

  for cmd in iptables-legacy-save ip6tables-legacy-save; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    rules="$("$cmd")" || die "cannot inspect $cmd rules; refusing to guess backend"
    FIREWALL_LEGACY_AVAILABLE=1
    if awk '
      /^:/ && $2 == "DROP" { found=1 }
      /^-A / && $2 != "RELAY_COVER_TRAFFIC" && $2 != "VPS_RELAY_DUMMY" &&
        $0 !~ /-j (RELAY_COVER_TRAFFIC|VPS_RELAY_DUMMY)( |$)/ { found=1 }
      END { exit !found }
    ' <<<"$rules"; then
      FIREWALL_LEGACY_RULES=1
    fi
  done
}

select_firewall_backend() {
  local recorded selected
  recorded="$(read_firewall_backend)" || return 1
  inspect_firewall_backends
  log "INFO" "firewall detection: nftables_rules=$FIREWALL_NFT_RULES legacy_rules=$FIREWALL_LEGACY_RULES recorded=${recorded:-none}"

  if ((FIREWALL_NFT_RULES && FIREWALL_LEGACY_RULES)); then
    die "both nftables and iptables-legacy have rules; consolidate firewall policies into one backend before proceeding"
  fi
  if [[ -n "$recorded" ]]; then
    selected="$recorded"
  elif ((FIREWALL_LEGACY_RULES)); then
    selected=iptables-legacy
  elif ((FIREWALL_NFT_AVAILABLE)); then
    selected=nftables
  elif ((FIREWALL_LEGACY_AVAILABLE)); then
    selected=iptables-legacy
  else
    die "no usable firewall backend found"
  fi
  if [[ "$selected" == nftables && "$FIREWALL_LEGACY_RULES" == 1 ]] ||
     [[ "$selected" == iptables-legacy && "$FIREWALL_NFT_RULES" == 1 ]]; then
    die "existing firewall rules conflict with recorded backend; reconcile policies or uninstall receiver before redetection"
  fi
  case "$selected" in
    nftables) [[ "$FIREWALL_NFT_AVAILABLE" == 1 ]] || die "nftables unavailable" ;;
    iptables-legacy)
      require_cmd iptables-legacy ip6tables-legacy iptables-legacy-save ip6tables-legacy-save
      ;;
  esac
  printf '%s\n' "$selected"
}

remove_xtables_project_chain() {
  local cmd="${1:?command required}" chain="${2:?chain required}" rule save_cmd
  local -a args
  command -v "$cmd" >/dev/null 2>&1 || return 0
  save_cmd="${cmd}-save"
  require_cmd "$save_cmd"
  rule="$("$save_cmd")" || return 1
  # Do not initialize an empty legacy filter table just to look for our chain.
  grep -q "^:$chain " <<<"$rule" || return 0
  while true; do
    rule="$("$cmd" -w 5 -S INPUT)" || return 1
    rule="$(awk -v chain="$chain" '
      $1 == "-A" && $2 == "INPUT" {
        for(i=1;i<NF;i++) if($i=="-j" && $(i+1)==chain) { $1="-D"; print; exit }
      }' <<<"$rule")"
    [[ -n "$rule" ]] || break
    read -r -a args <<<"$rule"
    "$cmd" -w 5 "${args[@]}" || return 1
  done
  if "$cmd" -w 5 -S "$chain" >/dev/null 2>&1; then
    "$cmd" -w 5 -F "$chain" || return 1
    "$cmd" -w 5 -X "$chain" || return 1
  fi
}

remove_receiver_firewall_rules() {
  local cmd chain table
  if command -v nft >/dev/null 2>&1; then
    # Check access before treating a missing project table as harmless.
    nft list tables >/dev/null || return 1
    for table in relay_cover_traffic vps_relay_dummy; do
      if nft list table inet "$table" >/dev/null 2>&1; then
        nft delete table inet "$table" || return 1
      fi
    done
  fi
  for cmd in iptables-legacy ip6tables-legacy; do
    for chain in RELAY_COVER_TRAFFIC VPS_RELAY_DUMMY; do
      remove_xtables_project_chain "$cmd" "$chain" || return 1
    done
  done
}
