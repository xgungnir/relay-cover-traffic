#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
export FIREWALL_TEST_DIR="$TEST_DIR" FIREWALL_BACKEND_FILE="$TEST_DIR/backend"
cat >"$TEST_DIR/bin/nft" <<'MOCK'
#!/usr/bin/env bash
[[ ! -e "$FIREWALL_TEST_DIR/nft-error" ]] || exit 1
cat "$FIREWALL_TEST_DIR/nft.json"
MOCK
for cmd in iptables-legacy-save ip6tables-legacy-save; do
  cat >"$TEST_DIR/bin/$cmd" <<'MOCK'
#!/usr/bin/env bash
[[ ! -e "$FIREWALL_TEST_DIR/legacy-error" ]] || exit 1
cat "$FIREWALL_TEST_DIR/${0##*/}.txt"
MOCK
done
for cmd in iptables-legacy ip6tables-legacy; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_DIR/bin/$cmd"
done
# A default nf_tables frontend must not override real legacy rules.
printf '#!/usr/bin/env bash\nprintf "iptables v1.8.11 (nf_tables)\\n"\n' >"$TEST_DIR/bin/iptables"
chmod +x "$TEST_DIR/bin/"*
export PATH="$TEST_DIR/bin:$PATH"
# shellcheck source=common/lib.sh
source "$ROOT_DIR/common/lib.sh"
# shellcheck source=common/firewall.sh
source "$ROOT_DIR/common/firewall.sh"
reset_case() {
  printf '{"nftables":[]}' >"$TEST_DIR/nft.json"
  : >"$TEST_DIR/iptables-legacy-save.txt"
  : >"$TEST_DIR/ip6tables-legacy-save.txt"
  rm -f "$FIREWALL_BACKEND_FILE" "$TEST_DIR/nft-error" "$TEST_DIR/legacy-error"
}
expect() {
  local expected="$1" actual
  actual="$(select_firewall_backend)"
  [[ "$actual" == "$expected" ]] || { echo "expected $expected, got $actual" >&2; exit 1; }
  count=$((count+1))
}
reject() {
  if (select_firewall_backend) >"$TEST_DIR/rejection.log" 2>&1; then
    echo "expected rejection" >&2; exit 1
  fi
  count=$((count+1))
}
nft_rule() {
  printf '{"nftables":[{"rule":{"family":"ip","table":"filter","chain":"INPUT","expr":[{"accept":null}]}}]}' >"$TEST_DIR/nft.json"
}
count=0
reset_case; expect nftables
nft_rule; expect nftables
reset_case; echo '-A INPUT -p tcp --dport 22 -j ACCEPT' >"$TEST_DIR/iptables-legacy-save.txt"; expect iptables-legacy
reset_case; echo ':INPUT DROP [0:0]' >"$TEST_DIR/ip6tables-legacy-save.txt"; expect iptables-legacy
nft_rule; reject
reset_case; printf '{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","policy":"drop"}}]}' >"$TEST_DIR/nft.json"; expect nftables
reset_case; echo iptables-legacy >"$FIREWALL_BACKEND_FILE"; expect iptables-legacy
nft_rule; reject
reset_case; echo nftables >"$FIREWALL_BACKEND_FILE"; echo '-A INPUT -j DROP' >"$TEST_DIR/iptables-legacy-save.txt"; reject
reset_case; echo garbage >"$FIREWALL_BACKEND_FILE"; reject
reset_case; touch "$TEST_DIR/nft-error"; reject
reset_case; touch "$TEST_DIR/legacy-error"; reject
reset_case; printf '{"nftables":[{"rule":{"family":"inet","table":"relay_cover_traffic","expr":[{"drop":null}]}}]}' >"$TEST_DIR/nft.json"; echo '-A INPUT -j RELAY_COVER_TRAFFIC' >"$TEST_DIR/iptables-legacy-save.txt"; echo '-A RELAY_COVER_TRAFFIC -j DROP' >>"$TEST_DIR/iptables-legacy-save.txt"; expect nftables
reset_case; printf '{"nftables":[{"chain":{"family":"inet","table":"filter","policy":"accept"}}]}' >"$TEST_DIR/nft.json"; expect nftables
reset_case; printf '{}' >"$TEST_DIR/nft.json"; reject
reset_case; mv "$TEST_DIR/bin/nft" "$TEST_DIR/nft.disabled"; expect iptables-legacy; mv "$TEST_DIR/nft.disabled" "$TEST_DIR/bin/nft"
printf '%s backend selection checks passed\n' "$count"
