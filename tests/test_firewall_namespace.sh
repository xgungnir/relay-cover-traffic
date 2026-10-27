#!/usr/bin/env bash
# Run as root on Linux with nftables, iptables and jq installed.
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --isolated ]]; then
  exec unshare --net -- bash "$0" --isolated
fi
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export FIREWALL_BACKEND_FILE="$TEST_DIR/backend" RELAY_SETUP_FIREWALL_SOURCE_ONLY=1
# shellcheck source=receiver/setup-firewall.sh
source "$ROOT_DIR/receiver/setup-firewall.sh"
NFT_INCLUDE_DIR="$TEST_DIR"
COVER_RECEIVER_PORT=18122
COVER_SOURCE_WHITELIST_V4_ENTRIES=(127.0.0.2)
COVER_SOURCE_WHITELIST_V6_ENTRIES=(::1)
expect() {
  local expected="$1" actual
  actual="$(select_firewall_backend)"
  [[ "$actual" == "$expected" ]] || { echo "expected $expected, got $actual" >&2; exit 1; }
  echo "PASS backend $expected"
}
reject() {
  if (select_firewall_backend) >"$TEST_DIR/reject.log" 2>&1; then
    echo 'expected backend rejection' >&2; exit 1
  fi
  echo "PASS rejection"
}
nft_snapshot() {
  nft -s list table inet sentinel >"$1"
}
expect nftables
iptables-legacy-save >"$TEST_DIR/empty-legacy.before"
remove_receiver_firewall_rules
iptables-legacy-save >"$TEST_DIR/empty-legacy.after"
cmp "$TEST_DIR/empty-legacy.before" "$TEST_DIR/empty-legacy.after"
echo 'PASS cleanup does not initialize an unused legacy filter table'
# The default iptables frontend on tmpjp remains nf_tables throughout.
iptables --version
iptables-legacy -A INPUT -p tcp --dport 34561 -j ACCEPT
expect iptables-legacy
apply_iptables_legacy_rules
iptables-legacy -S RELAY_COVER_TRAFFIC | grep -- '--dport 18122 -j DROP'
ip6tables-legacy -S RELAY_COVER_TRAFFIC | grep -- '--dport 18122 -j DROP'
ip6tables-legacy -A INPUT -p tcp --dport 34562 -j ACCEPT
printf iptables-legacy >"$FIREWALL_BACKEND_FILE"
expect iptables-legacy
# Cleanup must use explicit legacy binaries, even when default iptables is nft.
remove_receiver_firewall_rules
if iptables-legacy -S RELAY_COVER_TRAFFIC 2>/dev/null; then exit 1; fi
iptables-legacy -C INPUT -p tcp --dport 34561 -j ACCEPT
ip6tables-legacy -C INPUT -p tcp --dport 34562 -j ACCEPT
echo 'PASS legacy IPv4/IPv6 apply and cleanup preserve unrelated rules'
rm "$FIREWALL_BACKEND_FILE"
iptables-legacy -D INPUT -p tcp --dport 34561 -j ACCEPT
# IPv6-only legacy rules also select legacy.
expect iptables-legacy
ip6tables-legacy -D INPUT -p tcp --dport 34562 -j ACCEPT
nft add table inet sentinel
nft 'add chain inet sentinel input { type filter hook input priority 20; policy accept; }'
nft add rule inet sentinel input tcp dport 34563 accept
nft_snapshot "$TEST_DIR/sentinel.before"
expect nftables
apply_nftables_rules
nft -s list table inet relay_cover_traffic >"$TEST_DIR/project.before"
apply_nftables_rules
nft -s list table inet relay_cover_traffic >"$TEST_DIR/project.after"
cmp "$TEST_DIR/project.before" "$TEST_DIR/project.after"
echo 'PASS repeated nft apply is idempotent'
# Invalid nft input must fail without removing the old table.
COVER_RECEIVER_PORT=invalid
if apply_nftables_rules >"$TEST_DIR/invalid.log" 2>&1; then
  echo 'invalid nft transaction unexpectedly succeeded' >&2; exit 1
fi
COVER_RECEIVER_PORT=18122
nft -s list table inet relay_cover_traffic >"$TEST_DIR/project.failed"
cmp "$TEST_DIR/project.before" "$TEST_DIR/project.failed"
echo 'PASS invalid nft update preserves existing rules'
# Real iptables-nft rules are visible to the nft detector.
iptables-nft -A INPUT -p tcp --dport 34564 -j ACCEPT
expect nftables
iptables-legacy -A INPUT -p tcp --dport 34565 -j ACCEPT
reject
printf nftables >"$FIREWALL_BACKEND_FILE"
reject
remove_receiver_firewall_rules
if nft list table inet relay_cover_traffic 2>/dev/null; then exit 1; fi
nft_snapshot "$TEST_DIR/sentinel.after"
cmp "$TEST_DIR/sentinel.before" "$TEST_DIR/sentinel.after"
iptables-nft -C INPUT -p tcp --dport 34564 -j ACCEPT
iptables-legacy -C INPUT -p tcp --dport 34565 -j ACCEPT
echo 'PASS mixed-backend cleanup preserves all unrelated rules'
echo 'All isolated kernel firewall checks passed'
