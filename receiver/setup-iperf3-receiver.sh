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

ENV_FILE="/etc/relay-cover-traffic/receiver.env"
ENV_SOURCE="$SCRIPT_DIR/../config/receiver.env"
LEGACY_UNIT_FILE="/etc/systemd/system/relay-cover-receiver.service"
UNIT_FILE_V4="/etc/systemd/system/relay-cover-receiver-v4.service"
UNIT_FILE_V6="/etc/systemd/system/relay-cover-receiver-v6.service"

interface_is_excluded_for_iperf3_bind() {
  local dev="${1:?interface name is required}"

  case "$dev" in
    lo|warp|warp*|wg|wg[0-9]*|wgcf|tun|tun[0-9]*|tailscale|tailscale[0-9]*|docker*|br-*|virbr*|veth*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

detect_iperf3_bind_address_v4() {
  local _index
  local dev
  local family
  local cidr
  local addr

  while read -r _index dev family cidr _; do
    [[ "$family" == "inet" ]] || continue
    interface_is_excluded_for_iperf3_bind "$dev" && continue

    addr="${cidr%%/*}"
    is_ipv4_literal "$addr" || continue
    printf '%s\n' "$addr"
    return 0
  done < <(ip -o -4 addr show scope global up)

  return 1
}

detect_iperf3_bind_address_v6() {
  local _index
  local dev
  local family
  local cidr
  local addr

  while read -r _index dev family cidr _; do
    [[ "$family" == "inet6" ]] || continue
    interface_is_excluded_for_iperf3_bind "$dev" && continue

    addr="${cidr%%/*}"
    is_ipv6_literal "$addr" || continue
    printf '%s\n' "$addr"
    return 0
  done < <(ip -o -6 addr show scope global up)

  return 1
}

resolve_iperf3_bind_address_v4() {
  if [[ -n "${COVER_BIND_ADDRESS_V4:-}" ]]; then
    is_ipv4_literal "$COVER_BIND_ADDRESS_V4" || die "COVER_BIND_ADDRESS_V4 must be an IPv4 literal when set"
    printf '%s\n' "$COVER_BIND_ADDRESS_V4"
    return 0
  fi

  detect_iperf3_bind_address_v4 || return 1
}

resolve_iperf3_bind_address_v6() {
  if [[ -n "${COVER_BIND_ADDRESS_V6:-}" ]]; then
    is_ipv6_literal "$COVER_BIND_ADDRESS_V6" || die "COVER_BIND_ADDRESS_V6 must be an IPv6 literal when set"
    printf '%s\n' "$COVER_BIND_ADDRESS_V6"
    return 0
  fi

  detect_iperf3_bind_address_v6 || return 1
}

write_receiver_unit() {
  local unit_file="${1:?unit file is required}"
  local address_family="${2:?address family is required}"
  local bind_address="${3:?bind address is required}"

  log "INFO" "writing $address_family iperf3 receiver unit to $unit_file"
  cat >"$unit_file" <<UNIT
[Unit]
Description=iperf3 cover traffic receiver (${address_family})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/iperf3 --server --bind ${bind_address} --port ${COVER_RECEIVER_PORT} --interval 0
SuccessExitStatus=1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
  chmod 0644 "$unit_file"
}

require_root
require_cmd ip iperf3 systemctl install
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env COVER_RECEIVER_PORT
validate_port "$COVER_RECEIVER_PORT" || die "invalid COVER_RECEIVER_PORT: $COVER_RECEIVER_PORT"

COVER_BIND_ADDRESS_V4_EFFECTIVE="$(resolve_iperf3_bind_address_v4 || true)"
COVER_BIND_ADDRESS_V6_EFFECTIVE="$(resolve_iperf3_bind_address_v6 || true)"

[[ -n "$COVER_BIND_ADDRESS_V4_EFFECTIVE" || -n "$COVER_BIND_ADDRESS_V6_EFFECTIVE" ]] || \
  die "could not auto-detect any non-warp global bind address; set COVER_BIND_ADDRESS_V4 or COVER_BIND_ADDRESS_V6 manually"

if [[ -n "$COVER_BIND_ADDRESS_V4_EFFECTIVE" ]]; then
  log "INFO" "IPv4 iperf3 receiver will bind to ${COVER_BIND_ADDRESS_V4_EFFECTIVE}:${COVER_RECEIVER_PORT}"
else
  log "WARN" "no IPv4 iperf3 receiver will be installed"
fi

if [[ -n "$COVER_BIND_ADDRESS_V6_EFFECTIVE" ]]; then
  log "INFO" "IPv6 iperf3 receiver will bind to [${COVER_BIND_ADDRESS_V6_EFFECTIVE}]:${COVER_RECEIVER_PORT}"
else
  log "WARN" "no IPv6 iperf3 receiver will be installed"
fi

log "INFO" "disabling Debian's default iperf3 service on receiver node"
systemctl disable --now iperf3 || true

log "INFO" "stopping project iperf3 receiver units if present"
systemctl disable --now \
  relay-cover-receiver.service \
  relay-cover-receiver-v4.service \
  relay-cover-receiver-v6.service \
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true

rm -f \
  "$LEGACY_UNIT_FILE" \
  "$UNIT_FILE_V4" \
  "$UNIT_FILE_V6" \
  /etc/systemd/system/iperf3-dummy-receiver.service \
  /etc/systemd/system/iperf3-dummy-receiver-v4.service \
  /etc/systemd/system/iperf3-dummy-receiver-v6.service

if [[ -n "$COVER_BIND_ADDRESS_V4_EFFECTIVE" ]]; then
  write_receiver_unit "$UNIT_FILE_V4" "IPv4" "$COVER_BIND_ADDRESS_V4_EFFECTIVE"
fi

if [[ -n "$COVER_BIND_ADDRESS_V6_EFFECTIVE" ]]; then
  write_receiver_unit "$UNIT_FILE_V6" "IPv6" "$COVER_BIND_ADDRESS_V6_EFFECTIVE"
fi

systemctl daemon-reload

if [[ -n "$COVER_BIND_ADDRESS_V4_EFFECTIVE" ]]; then
  systemctl enable --now relay-cover-receiver-v4.service
fi

if [[ -n "$COVER_BIND_ADDRESS_V6_EFFECTIVE" ]]; then
  systemctl enable --now relay-cover-receiver-v6.service
fi

systemctl reset-failed relay-cover-receiver.service 2>/dev/null || true
systemctl reset-failed \
  relay-cover-receiver-v4.service \
  relay-cover-receiver-v6.service \
  iperf3-dummy-receiver.service \
  iperf3-dummy-receiver-v4.service \
  iperf3-dummy-receiver-v6.service 2>/dev/null || true
log "INFO" "iperf3 cover traffic receiver setup complete"
