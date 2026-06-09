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

ENV_FILE="/etc/relay-cover-traffic/relay.env"
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"
SING_BOX_CONFIG_DIR="/etc/sing-box"
SING_BOX_CONFIG="$SING_BOX_CONFIG_DIR/config.json"
SING_BOX_DATA_DIR="/var/lib/sing-box"

require_root
require_cmd install systemctl
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"

export DEBIAN_FRONTEND=noninteractive

install_sing_box_from_sagernet_repo
enable_sing_box_service

if ! sing_box_config_ready "$SING_BOX_CONFIG"; then
  log "WARN" "$SING_BOX_CONFIG is missing or empty"
  die "fix $SING_BOX_CONFIG before rerunning relay install; this project does not generate or overwrite sing-box config"
fi

require_cmd sing-box
install -d -m 0755 "$SING_BOX_DATA_DIR"

log "INFO" "checking sing-box config: sing-box check -D $SING_BOX_DATA_DIR -C $SING_BOX_CONFIG_DIR"
if ! sing-box check -D "$SING_BOX_DATA_DIR" -C "$SING_BOX_CONFIG_DIR"; then
  die "sing-box config check failed; fix $SING_BOX_CONFIG before rerunning relay install"
fi

log "INFO" "restarting sing-box.service"
systemctl restart sing-box.service

log "INFO" "sing-box.service setup complete"
