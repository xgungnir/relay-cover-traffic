#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/../common/lib.sh" ]]; then
  # shellcheck source=common/lib.sh
  source "$SCRIPT_DIR/../common/lib.sh"
elif [[ -r /usr/local/lib/relay-cover-traffic/lib.sh ]]; then
  # shellcheck source=common/lib.sh
  source /usr/local/lib/relay-cover-traffic/lib.sh
else
  echo "common library not found" >&2
  exit 1
fi

ENV_FILE="/etc/relay-cover-traffic/relay.env"

require_root
require_cmd tc
load_env_file "$ENV_FILE"
require_env EGRESS_DEV

log "INFO" "removing root qdisc from $EGRESS_DEV if present"
tc qdisc del dev "$EGRESS_DEV" root 2>/dev/null || true
log "INFO" "tc QoS removed from $EGRESS_DEV"
