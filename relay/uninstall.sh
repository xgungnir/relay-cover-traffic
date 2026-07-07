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
PURGE="false"

case "${1:-}" in
  "")
    ;;
  --purge)
    PURGE="true"
    ;;
  *)
    die "usage: $0 [--purge]"
    ;;
esac

main() {
  require_root
  require_cmd systemctl rm
  require_no_legacy_relay_resources

  log "INFO" "disabling relay cover sender units"
  systemctl disable --now relay-cover-sender.timer 2>/dev/null || true
  systemctl disable --now relay-cover-sender.service 2>/dev/null || true
  systemctl disable --now iperf3-dummy-hourly.timer 2>/dev/null || true
  systemctl disable --now iperf3-dummy-hourly.service 2>/dev/null || true

  log "INFO" "removing relay sender units and helper files"
  rm -f \
    /etc/systemd/system/relay-cover-sender.service \
    /etc/systemd/system/relay-cover-sender.timer \
    /etc/systemd/system/iperf3-dummy-hourly.service \
    /etc/systemd/system/iperf3-dummy-hourly.timer \
    /usr/local/sbin/relay-cover-sender-hourly.sh \
    /usr/local/sbin/dummy-sender-hourly.sh \
    /usr/local/lib/relay-cover-traffic/lib.sh

  rmdir /usr/local/lib/relay-cover-traffic 2>/dev/null || true

  if [[ "$PURGE" == "true" ]]; then
    log "WARN" "purging $ENV_FILE"
    rm -f "$ENV_FILE"
    rmdir /etc/relay-cover-traffic 2>/dev/null || true
  else
    log "INFO" "preserving $ENV_FILE"
  fi

  systemctl daemon-reload
  systemctl reset-failed relay-cover-sender.service relay-cover-sender.timer iperf3-dummy-hourly.service iperf3-dummy-hourly.timer 2>/dev/null || true
  log "INFO" "relay uninstall complete"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
