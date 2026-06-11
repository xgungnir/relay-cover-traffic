#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/../common/lib.sh" ]]; then
  # shellcheck source=common/lib.sh
  source "$SCRIPT_DIR/../common/lib.sh"
elif [[ -r /usr/local/lib/relay-cover-traffic/lib.sh ]]; then
  # shellcheck source=common/lib.sh
  source /usr/local/lib/relay-cover-traffic/lib.sh
else
  echo "common library not found" >&2
  exit 1
fi

ENV_FILE="/etc/relay-cover-traffic/relay.env"
ENV_SOURCE="$SCRIPT_DIR/../config/relay.env"
LOCK_FILE="/run/relay-cover-sender.lock"
MAX_COVER_BPS=5000000

target_hosts=()
target_ports=()
target_durations=()

random_between() {
  local min="${1:?min is required}"
  local max="${2:?max is required}"
  local span=$((max - min + 1))
  local value=$(((RANDOM << 16) ^ RANDOM))

  printf '%s\n' "$((min + (value % span)))"
}

target_display() {
  local host="${1:?host is required}"
  local port="${2:?port is required}"

  if is_ipv6_literal "$host"; then
    printf '[%s]:%s' "$host" "$port"
  else
    printf '%s:%s' "$host" "$port"
  fi
}

load_targets() {
  local host
  local port

  while IFS=$'\t' read -r host port; do
    target_hosts+=("$host")
    target_ports+=("$port")
  done < <(parse_target_list "$COVER_TARGETS")
}

shuffle_targets() {
  local count="${#target_hosts[@]}"
  local i
  local j
  local tmp_host
  local tmp_port

  for ((i = count - 1; i > 0; i--)); do
    j="$(random_between 0 "$i")"

    tmp_host="${target_hosts[$i]}"
    tmp_port="${target_ports[$i]}"
    target_hosts[i]="${target_hosts[j]}"
    target_ports[i]="${target_ports[j]}"
    target_hosts[j]="$tmp_host"
    target_ports[j]="$tmp_port"
  done
}

target_order_string() {
  local count="${#target_hosts[@]}"
  local i
  local sep=""
  local output=""

  for ((i = 0; i < count; i++)); do
    output="${output}${sep}$(target_display "${target_hosts[$i]}" "${target_ports[$i]}")"
    sep=", "
  done

  printf '%s\n' "$output"
}

target_duration_string() {
  local count="${#target_hosts[@]}"
  local i
  local sep=""
  local output=""

  for ((i = 0; i < count; i++)); do
    output="${output}${sep}$(target_display "${target_hosts[$i]}" "${target_ports[$i]}")=${target_durations[$i]}s"
    sep=", "
  done

  printf '%s\n' "$output"
}

allocate_target_durations() {
  local total_duration="${1:?duration is required}"
  local cut
  local exists
  local existing_cut
  local i
  local j
  local prev=0
  local tmp
  local -a cuts=()

  target_durations=()

  if [[ "$target_count" -eq 1 ]]; then
    target_durations=("$total_duration")
    return 0
  fi

  while [[ "${#cuts[@]}" -lt "$((target_count - 1))" ]]; do
    cut="$(random_between 1 "$((total_duration - 1))")"
    exists=0
    for existing_cut in "${cuts[@]}"; do
      if [[ "$existing_cut" -eq "$cut" ]]; then
        exists=1
        break
      fi
    done

    if [[ "$exists" -eq 0 ]]; then
      cuts+=("$cut")
    fi
  done

  for ((i = 0; i < ${#cuts[@]}; i++)); do
    for ((j = i + 1; j < ${#cuts[@]}; j++)); do
      if [[ "${cuts[$j]}" -lt "${cuts[$i]}" ]]; then
        tmp="${cuts[$i]}"
        cuts[$i]="${cuts[$j]}"
        cuts[$j]="$tmp"
      fi
    done
  done

  cuts+=("$total_duration")
  for cut in "${cuts[@]}"; do
    target_durations+=("$((cut - prev))")
    prev="$cut"
  done
}

validate_cover_type() {
  case "${COVER_TYPE:-}" in
    auto|udp|tcp)
      ;;
    *)
      die "COVER_TYPE must be one of: auto, udp, tcp"
      ;;
  esac
}

choose_cover_type() {
  case "$COVER_TYPE" in
    udp|tcp)
      printf '%s\n' "$COVER_TYPE"
      ;;
    auto)
      if [[ "$(random_between 0 1)" -eq 0 ]]; then
        printf '%s\n' "udp"
      else
        printf '%s\n' "tcp"
      fi
      ;;
  esac
}

run_iperf3_process() {
  local protocol="${1:?protocol is required}"
  local host="${2:?host is required}"
  local port="${3:?port is required}"
  local segment_duration="${4:?segment duration is required}"
  local hard_timeout
  local -a args

  args=(-c "$host" -b "$effective_rate" -t "$segment_duration" -p "$port" --connect-timeout "$connect_timeout_ms")

  if [[ "$protocol" == "udp" ]]; then
    args=(-c "$host" -u -b "$effective_rate" -l 1200 -t "$segment_duration" -p "$port" --connect-timeout "$connect_timeout_ms")
  fi

  hard_timeout=$((segment_duration + 10#$COVER_RETRY_DELAY_SECONDS + 15))
  timeout --kill-after=5s "$hard_timeout" iperf3 "${args[@]}"
}

require_root
require_cmd date flock iperf3 sleep timeout tr
if [[ -f "$ENV_SOURCE" ]]; then
  sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
fi
load_env_file "$ENV_FILE"
require_env COVER_TARGETS COVER_RATE COVER_MIN_SECONDS COVER_MAX_SECONDS COVER_RETRY_DELAY_SECONDS COVER_MAX_SEGMENT_SECONDS
COVER_TYPE="${COVER_TYPE:-auto}"
validate_cover_type
load_targets

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "INFO" "another cover sender run is already active; exiting"
  exit 0
fi

is_positive_int "$COVER_MIN_SECONDS" || die "COVER_MIN_SECONDS must be a positive integer"
is_positive_int "$COVER_MAX_SECONDS" || die "COVER_MAX_SECONDS must be a positive integer"
is_positive_int "$COVER_RETRY_DELAY_SECONDS" || die "COVER_RETRY_DELAY_SECONDS must be a positive integer"
is_positive_int "$COVER_MAX_SEGMENT_SECONDS" || die "COVER_MAX_SEGMENT_SECONDS must be a positive integer"

target_count="${#target_hosts[@]}"
if [[ "$COVER_MAX_SECONDS" -gt 3600 ]]; then
  die "COVER_MAX_SECONDS must be <= 3600"
fi

if [[ "$COVER_MIN_SECONDS" -gt "$COVER_MAX_SECONDS" ]]; then
  die "COVER_MIN_SECONDS must be <= COVER_MAX_SECONDS"
fi

if [[ "$COVER_MAX_SECONDS" -lt "$target_count" ]]; then
  die "COVER_MAX_SECONDS must be at least the number of COVER_TARGETS ($target_count)"
fi

effective_rate="$COVER_RATE"
cover_rate_bps="$(rate_to_bps "$COVER_RATE")" || die "invalid COVER_RATE: $COVER_RATE"
if [[ "${ALLOW_COVER_RATE_ABOVE_5M:-false}" != "true" && "$cover_rate_bps" -gt "$MAX_COVER_BPS" ]]; then
  log "WARN" "COVER_RATE=$COVER_RATE is above 5 Mbps; capping this run at 5M"
  effective_rate="5M"
fi
connect_timeout_ms=$((10#$COVER_RETRY_DELAY_SECONDS * 1000))

effective_min="$COVER_MIN_SECONDS"
if [[ "$effective_min" -lt "$target_count" ]]; then
  log "WARN" "COVER_MIN_SECONDS=$COVER_MIN_SECONDS is lower than target count; using ${target_count}s minimum for this run"
  effective_min="$target_count"
fi

duration="$(random_between "$effective_min" "$COVER_MAX_SECONDS")"
if [[ "$duration" -eq 3600 ]]; then
  delay=0
else
  delay="$(random_between 0 "$((3600 - duration))")"
fi

shuffle_targets
allocate_target_durations "$duration"

log "INFO" "cover traffic selected: delay=${delay}s total_duration=${duration}s rate=${effective_rate} type=${COVER_TYPE} target_count=${target_count}"
log "INFO" "cover target order: $(target_order_string)"
log "INFO" "cover target durations: $(target_duration_string)"
sleep "$delay"

run_target_until_deadline() {
  local host="${1:?host is required}"
  local port="${2:?port is required}"
  local allocated_duration="${3:?duration is required}"
  local target
  local deadline
  local now
  local remaining
  local segment_duration
  local attempt=0
  local had_success=0
  local had_failure=0
  local rc
  local retry_sleep
  local protocol

  target="$(target_display "$host" "$port")"
  deadline="$(($(date +%s) + allocated_duration))"

  log "INFO" "starting iperf3 cover target window: target=${target} duration=${allocated_duration}s max_segment=${COVER_MAX_SEGMENT_SECONDS}s retry_delay=${COVER_RETRY_DELAY_SECONDS}s cover_type=${COVER_TYPE}"

  while :; do
    now="$(date +%s)"
    remaining=$((deadline - now))
    if [[ "$remaining" -le 0 ]]; then
      break
    fi

    segment_duration="$remaining"
    if [[ "$segment_duration" -gt "$COVER_MAX_SEGMENT_SECONDS" ]]; then
      segment_duration="$COVER_MAX_SEGMENT_SECONDS"
    fi

    attempt=$((attempt + 1))
    protocol="$(choose_cover_type)"
    log "INFO" "starting iperf3 ${protocol} cover segment: target=${target} attempt=${attempt} duration=${segment_duration}s"
    if run_iperf3_process "$protocol" "$host" "$port" "$segment_duration"; then
      had_success=1
      log "INFO" "iperf3 ${protocol} cover segment completed: target=${target} attempt=${attempt}"
    else
      rc=$?
      had_failure=1
      log "WARN" "iperf3 ${protocol} cover segment failed with exit code $rc; retrying until target window ends: target=${target} attempt=${attempt}"

      now="$(date +%s)"
      remaining=$((deadline - now))
      if [[ "$remaining" -le 0 ]]; then
        break
      fi

      retry_sleep="$COVER_RETRY_DELAY_SECONDS"
      if [[ "$retry_sleep" -gt "$remaining" ]]; then
        retry_sleep="$remaining"
      fi
      log "INFO" "waiting ${retry_sleep}s before retry: target=${target}"
      sleep "$retry_sleep"
    fi
  done

  if [[ "$had_success" -eq 0 ]]; then
    log "ERROR" "target window ended without a successful iperf3 segment: target=${target}"
    return 1
  fi

  if [[ "$had_failure" -ne 0 ]]; then
    log "WARN" "target window completed with one or more retried iperf3 failures: target=${target}"
  else
    log "INFO" "target window completed successfully: target=${target}"
  fi
}

failed=0
for ((i = 0; i < target_count; i++)); do
  run_duration="${target_durations[$i]}"

  if run_target_until_deadline "${target_hosts[$i]}" "${target_ports[$i]}" "$run_duration"; then
    :
  else
    rc=$?
    failed=1
    log "ERROR" "iperf3 cover target window failed with exit code $rc: target=$(target_display "${target_hosts[$i]}" "${target_ports[$i]}")"
  fi
done

if [[ "$failed" -ne 0 ]]; then
  die "one or more iperf3 cover runs failed"
fi

log "INFO" "all iperf3 cover runs completed successfully"
