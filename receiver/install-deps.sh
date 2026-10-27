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
require_root
require_cmd apt-get systemctl

export DEBIAN_FRONTEND=noninteractive

log "INFO" "installing receiver dependencies"
apt-get update
apt_get_install iperf3 systemd nftables iptables ca-certificates curl jq

log "INFO" "receiver dependency setup complete"
