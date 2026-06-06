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
UNIT_FILE="/etc/systemd/system/relay-cover-qos.service"

require_root
require_cmd systemctl install tr
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env EGRESS_DEV RELAY_QOS_TARGETS COVER_TARGETS TC_TOTAL_RATE TC_RELAY_RATE TC_RELAY_CEIL TC_COVER_RATE TC_COVER_CEIL TC_DEFAULT_RATE TC_DEFAULT_CEIL
parse_target_list "$RELAY_QOS_TARGETS" >/dev/null
parse_target_list "$COVER_TARGETS" >/dev/null

log "INFO" "installing relay cover QoS helper scripts"
install_file "$SCRIPT_DIR/setup-qos.sh" "/usr/local/sbin/relay-cover-setup-qos.sh" "0755"
install_file "$SCRIPT_DIR/remove-qos.sh" "/usr/local/sbin/relay-cover-remove-qos.sh" "0755"
install_file "$SCRIPT_DIR/../common/lib.sh" "/usr/local/lib/relay-cover-traffic/lib.sh" "0644"

log "INFO" "writing systemd unit to $UNIT_FILE"
cat >"$UNIT_FILE" <<'UNIT'
[Unit]
Description=Apply relay cover traffic QoS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/relay-cover-setup-qos.sh
ExecStop=/usr/local/sbin/relay-cover-remove-qos.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT_FILE"

systemctl daemon-reload
systemctl enable --now relay-cover-qos.service

log "INFO" "relay-cover-qos.service installed and enabled"
