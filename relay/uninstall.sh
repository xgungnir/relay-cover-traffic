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

require_root
require_cmd systemctl rm grep

if [[ -f "$ENV_SOURCE" ]]; then
  sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
fi

if [[ -f "$ENV_FILE" ]]; then
  load_env_file "$ENV_FILE"
else
  log "WARN" "$ENV_FILE not found; tc qdisc removal by EGRESS_DEV will be skipped"
fi

log "INFO" "disabling relay cover traffic systemd units"
systemctl disable --now relay-cover-sender.timer 2>/dev/null || true
systemctl disable --now relay-cover-sender.service 2>/dev/null || true
systemctl disable --now relay-cover-qos.service 2>/dev/null || true
systemctl disable --now iperf3-dummy-hourly.timer 2>/dev/null || true
systemctl disable --now iperf3-dummy-hourly.service 2>/dev/null || true
systemctl disable --now tc-qos.service 2>/dev/null || true

if [[ -n "${EGRESS_DEV:-}" ]] && command -v tc >/dev/null 2>&1; then
  log "INFO" "removing tc root qdisc from $EGRESS_DEV if present"
  tc qdisc del dev "$EGRESS_DEV" root 2>/dev/null || true
fi

log "INFO" "removing project units and installed helper scripts"
rm -f \
  /etc/systemd/system/relay-cover-sender.service \
  /etc/systemd/system/relay-cover-sender.timer \
  /etc/systemd/system/relay-cover-qos.service \
  /etc/systemd/system/iperf3-dummy-hourly.service \
  /etc/systemd/system/iperf3-dummy-hourly.timer \
  /etc/systemd/system/tc-qos.service \
  /usr/local/sbin/relay-cover-setup-qos.sh \
  /usr/local/sbin/relay-cover-remove-qos.sh \
  /usr/local/sbin/relay-cover-sender-hourly.sh \
  /usr/local/sbin/setup-tc-qos.sh \
  /usr/local/sbin/remove-tc-qos.sh \
  /usr/local/sbin/dummy-sender-hourly.sh

rm -f /usr/local/lib/relay-cover-traffic/lib.sh
rmdir /usr/local/lib/relay-cover-traffic 2>/dev/null || true
rm -f /usr/local/lib/vps-relay-dummy/lib.sh
rmdir /usr/local/lib/vps-relay-dummy 2>/dev/null || true

if [[ "$PURGE" == "true" ]]; then
  log "WARN" "purging $ENV_FILE"
  rm -f "$ENV_FILE"
  rmdir /etc/relay-cover-traffic 2>/dev/null || true

  if [[ -f /etc/realm/config.toml ]]; then
    if grep -q '[^[:space:]]' /etc/realm/config.toml; then
      log "WARN" "preserving non-empty /etc/realm/config.toml"
    else
      log "INFO" "removing empty /etc/realm/config.toml"
      rm -f /etc/realm/config.toml
      rmdir /etc/realm 2>/dev/null || true
    fi
  fi
else
  log "INFO" "preserving $ENV_FILE"
fi

systemctl daemon-reload
systemctl reset-failed \
  realm.service \
  relay-cover-qos.service \
  relay-cover-sender.service \
  relay-cover-sender.timer \
  tc-qos.service \
  iperf3-dummy-hourly.service \
  iperf3-dummy-hourly.timer 2>/dev/null || true
log "INFO" "relay uninstall complete"
