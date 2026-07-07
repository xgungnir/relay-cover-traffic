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

ENV_FILE="${RELAY_RUNTIME_ENV_FILE:-/etc/relay-cover-traffic/relay.env}"
SERVICE_FILE="${RELAY_SENDER_SERVICE_FILE:-/etc/systemd/system/relay-cover-sender.service}"
TIMER_FILE="${RELAY_SENDER_TIMER_FILE:-/etc/systemd/system/relay-cover-sender.timer}"
INSTALLED_SCRIPT="${RELAY_SENDER_INSTALLED_SCRIPT:-/usr/local/sbin/relay-cover-sender-hourly.sh}"
INSTALLED_LIB="${RELAY_SENDER_INSTALLED_LIB:-/usr/local/lib/relay-cover-traffic/lib.sh}"

write_sender_service() {
  cat >"$SERVICE_FILE" <<SERVICE
[Unit]
Description=Run randomized hourly relay cover traffic
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=$INSTALLED_SCRIPT
RuntimeMaxSec=3600
SuccessExitStatus=SIGTERM SIGINT
SERVICE
  chmod 0644 "$SERVICE_FILE"
}

write_sender_timer() {
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
}

main() {
  require_root
  require_cmd systemctl install iperf3 grep

  load_and_validate_relay_env "$ENV_FILE" 1
  require_relay_iperf3_capabilities

  log "INFO" "installing relay cover sender helper"
  install_file "$SCRIPT_DIR/cover-sender-hourly.sh" "$INSTALLED_SCRIPT" "0755"
  install_file "$SCRIPT_DIR/../common/lib.sh" "$INSTALLED_LIB" "0644"

  if [[ "${RELAY_TEST_FORCE_INSTALL_COVER_SENDER_FAIL:-0}" == "1" ]]; then
    die "forced install-cover-sender failure for tests"
  fi

  log "INFO" "writing sender systemd unit: $SERVICE_FILE"
  write_sender_service

  log "INFO" "writing sender timer unit: $TIMER_FILE"
  write_sender_timer

  systemctl daemon-reload
  systemctl reset-failed relay-cover-sender.service relay-cover-sender.timer 2>/dev/null || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
