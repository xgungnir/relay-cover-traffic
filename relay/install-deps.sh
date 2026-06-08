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

ENV_FILE="/etc/relay-cover-traffic/relay.env"
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"

require_root
require_cmd apt-get systemctl
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"

export DEBIAN_FRONTEND=noninteractive

log "INFO" "installing relay dependencies"
apt-get update
apt_get_install iperf3 iproute2 systemd ca-certificates curl jq util-linux tar

log "INFO" "disabling Debian's default iperf3 service on relay node"
disable_default_iperf3_service

if [[ -x /usr/local/bin/realm ]]; then
  log "INFO" "realm binary found at /usr/local/bin/realm"
elif [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
  if [[ -n "${REALM_TARBALL_URL:-}" ]]; then
    log "INFO" "realm binary not found; setup-realm-service.sh can install it from REALM_TARBALL_URL"
  else
    log "WARN" "realm binary not found and REALM_TARBALL_URL is not set in $ENV_FILE"
  fi
else
  log "INFO" "$ENV_FILE not found yet; setup-realm-service.sh will need REALM_TARBALL_URL later"
fi

log "INFO" "relay dependency setup complete"
