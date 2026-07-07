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
if [[ -r "$SCRIPT_DIR/../common/sb.sh" ]]; then
  # shellcheck source=common/sb.sh
  source "$SCRIPT_DIR/../common/sb.sh"
else
  echo "common sing-box library not found" >&2
  exit 1
fi

require_root
require_cmd apt-get systemctl

export DEBIAN_FRONTEND=noninteractive

log "INFO" "installing receiver dependencies"
apt-get update
apt_get_install iperf3 systemd nftables iptables ca-certificates curl jq

install_sing_box_from_sagernet_repo
enable_sing_box_service

log "WARN" "This project installs the sing-box package when needed, but it does not generate or overwrite $SING_BOX_CONFIG."
log "WARN" "Please make sure your sing-box service is configured before relying on the downstream service."
log "INFO" "receiver dependency setup complete"
