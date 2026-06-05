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
SERVICE_FILE="/etc/systemd/system/relay-cover-sender.service"
TIMER_FILE="/etc/systemd/system/relay-cover-sender.timer"

require_root
require_cmd iperf3 systemctl install tr
load_env_file "$ENV_FILE"
require_env COVER_TARGETS COVER_RATE COVER_MIN_SECONDS COVER_MAX_SECONDS COVER_RETRY_DELAY_SECONDS COVER_MAX_SEGMENT_SECONDS
COVER_TYPE="${COVER_TYPE:-auto}"
parse_target_list "$COVER_TARGETS" >/dev/null
is_positive_int "$COVER_MIN_SECONDS" || die "COVER_MIN_SECONDS must be a positive integer"
is_positive_int "$COVER_MAX_SECONDS" || die "COVER_MAX_SECONDS must be a positive integer"
is_positive_int "$COVER_RETRY_DELAY_SECONDS" || die "COVER_RETRY_DELAY_SECONDS must be a positive integer"
is_positive_int "$COVER_MAX_SEGMENT_SECONDS" || die "COVER_MAX_SEGMENT_SECONDS must be a positive integer"
case "$COVER_TYPE" in
  auto|udp|tcp)
    ;;
  *)
    die "COVER_TYPE must be one of: auto, udp, tcp"
    ;;
esac

log "INFO" "installing cover sender helper script"
install_file "$SCRIPT_DIR/cover-sender-hourly.sh" "/usr/local/sbin/relay-cover-sender-hourly.sh" "0755"
install_file "$SCRIPT_DIR/../common/lib.sh" "/usr/local/lib/relay-cover-traffic/lib.sh" "0644"

log "INFO" "writing systemd service to $SERVICE_FILE"
cat >"$SERVICE_FILE" <<'SERVICE'
[Unit]
Description=Run randomized hourly relay cover traffic
After=network-online.target relay-cover-qos.service
Wants=network-online.target relay-cover-qos.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/relay-cover-sender-hourly.sh
SERVICE
chmod 0644 "$SERVICE_FILE"

log "INFO" "writing systemd timer to $TIMER_FILE"
cat >"$TIMER_FILE" <<'TIMER'
[Unit]
Description=Hourly randomized relay cover traffic timer

[Timer]
OnBootSec=5min
OnCalendar=hourly
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER
chmod 0644 "$TIMER_FILE"

systemctl daemon-reload
systemctl enable --now relay-cover-sender.timer

log "INFO" "relay-cover-sender.timer installed and enabled"
