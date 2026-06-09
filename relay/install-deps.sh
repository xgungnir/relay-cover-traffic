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

log "INFO" "installing relay dependencies"
apt-get update
apt_get_install iperf3 iproute2 systemd ca-certificates curl jq util-linux

log "INFO" "disabling Debian's default iperf3 service on relay node"
disable_default_iperf3_service

log "INFO" "relay dependency setup complete"
