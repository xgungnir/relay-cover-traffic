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
ENV_SOURCE="${RELAY_CANDIDATE_ENV_FILE:-$SCRIPT_DIR/../config/relay.env}"
ENV_EXAMPLE="${RELAY_CANDIDATE_ENV_EXAMPLE:-$SCRIPT_DIR/../config/relay.env.example}"
SERVICE_FILE="${RELAY_SENDER_SERVICE_FILE:-/etc/systemd/system/relay-cover-sender.service}"
TIMER_FILE="${RELAY_SENDER_TIMER_FILE:-/etc/systemd/system/relay-cover-sender.timer}"
INSTALLED_SCRIPT="${RELAY_SENDER_INSTALLED_SCRIPT:-/usr/local/sbin/relay-cover-sender-hourly.sh}"
INSTALLED_LIB="${RELAY_SENDER_INSTALLED_LIB:-/usr/local/lib/relay-cover-traffic/lib.sh}"

timer_was_enabled=0
timer_was_active=0
sender_was_running=0

backup_path() {
  local src="${1:?source path is required}"
  local dest="${2:?backup path is required}"

  if [[ -e "$src" ]]; then
    mkdir -p "${dest%/*}"
    cp -a "$src" "$dest"
    return 0
  fi

  return 1
}

restore_path() {
  local backup="${1:?backup path is required}"
  local dest="${2:?destination path is required}"

  if [[ -e "$backup" ]]; then
    mkdir -p "${dest%/*}"
    rm -rf "$dest"
    cp -a "$backup" "$dest"
  else
    rm -rf "$dest"
  fi
}

capture_unit_states() {
  if systemctl_is_enabled relay-cover-sender.timer; then
    timer_was_enabled=1
  fi

  if systemctl_is_activeish relay-cover-sender.timer; then
    timer_was_active=1
  fi

  if systemctl_is_activeish relay-cover-sender.service; then
    sender_was_running=1
  fi
}

restore_unit_states() {
  if [[ "$timer_was_enabled" -eq 1 ]]; then
    systemctl enable relay-cover-sender.timer >/dev/null 2>&1 || true
  else
    systemctl disable relay-cover-sender.timer >/dev/null 2>&1 || true
  fi

  if [[ "$timer_was_active" -eq 1 ]]; then
    systemctl start relay-cover-sender.timer >/dev/null 2>&1 || true
  else
    systemctl stop relay-cover-sender.timer >/dev/null 2>&1 || true
  fi

  if [[ "$sender_was_running" -eq 1 ]]; then
    systemctl start --no-block relay-cover-sender.service >/dev/null 2>&1 || true
  else
    systemctl stop relay-cover-sender.service >/dev/null 2>&1 || true
  fi
}

restore_previous_installation() {
  local backup_dir="${1:?backup dir is required}"

  log "WARN" "apply failed; restoring previous relay runtime env and installed assets"
  restore_path "$backup_dir/runtime/relay.env" "$ENV_FILE"
  restore_path "$backup_dir/systemd/relay-cover-sender.service" "$SERVICE_FILE"
  restore_path "$backup_dir/systemd/relay-cover-sender.timer" "$TIMER_FILE"
  restore_path "$backup_dir/bin/relay-cover-sender-hourly.sh" "$INSTALLED_SCRIPT"
  restore_path "$backup_dir/lib/lib.sh" "$INSTALLED_LIB"
  systemctl daemon-reload
  restore_unit_states
}

apply_changes() {
  log "INFO" "stopping relay-cover-sender.timer before applying new env"
  systemctl stop relay-cover-sender.timer >/dev/null 2>&1 || true

  if [[ "$sender_was_running" -eq 1 ]]; then
    log "INFO" "stopping active relay-cover-sender.service before applying new env"
    systemctl stop relay-cover-sender.service || return 1
  fi

  install_private_file_atomically "$ENV_SOURCE" "$ENV_FILE" || return 1
  log "INFO" "installed validated relay runtime env to $ENV_FILE"

  bash "$SCRIPT_DIR/install-cover-sender.sh" || return 1

  if [[ "$timer_was_enabled" -eq 1 ]]; then
    systemctl enable relay-cover-sender.timer || return 1
  else
    systemctl disable relay-cover-sender.timer >/dev/null 2>&1 || true
  fi

  if [[ "$timer_was_active" -eq 1 ]]; then
    systemctl start relay-cover-sender.timer || return 1
  fi

  if [[ "$sender_was_running" -eq 1 ]]; then
    log "INFO" "restarting relay-cover-sender.service with updated env"
    systemctl start --no-block relay-cover-sender.service || return 1
  fi
}

main() {
  local backup_dir

  require_config_env_file "$ENV_SOURCE" "$ENV_EXAMPLE"
  require_root
  require_cmd cp install ip iperf3 mkdir mktemp mv rm systemctl grep

  load_and_validate_relay_env "$ENV_SOURCE" 1
  require_no_legacy_relay_resources
  require_relay_iperf3_capabilities
  log "INFO" "validated relay candidate config: EGRESS_DEV=$EGRESS_DEV COVER_RATE=${RELAY_COVER_RATE_BPS}bps COVER_DURATION_RANGE=$COVER_DURATION_RANGE COVER_TYPE=$COVER_TYPE target_count=$RELAY_VALIDATED_TARGET_COUNT"

  capture_unit_states
  log "INFO" "captured current sender state: timer_enabled=$timer_was_enabled timer_active=$timer_was_active sender_running=$sender_was_running"

  backup_dir="$(mktemp -d)"
  backup_path "$ENV_FILE" "$backup_dir/runtime/relay.env" || true
  backup_path "$SERVICE_FILE" "$backup_dir/systemd/relay-cover-sender.service" || true
  backup_path "$TIMER_FILE" "$backup_dir/systemd/relay-cover-sender.timer" || true
  backup_path "$INSTALLED_SCRIPT" "$backup_dir/bin/relay-cover-sender-hourly.sh" || true
  backup_path "$INSTALLED_LIB" "$backup_dir/lib/lib.sh" || true

  if ! apply_changes; then
    restore_previous_installation "$backup_dir"
    rm -rf "$backup_dir"
    die "failed to apply relay env; previous runtime env and sender state were restored"
  fi

  rm -rf "$backup_dir"
  log "INFO" "relay env changes applied"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
