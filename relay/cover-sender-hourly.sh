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

ENV_FILE="${RELAY_RUNTIME_ENV_FILE:-/etc/relay-cover-traffic/relay.env}"
LOCK_FILE="${RELAY_SENDER_LOCK_FILE:-/run/relay-cover-sender.lock}"
readonly RETRY_DELAY_SECONDS=5
readonly MAX_SEGMENT_SECONDS=30
readonly CONNECT_TIMEOUT_MS=5000
readonly MIN_TARGET_WINDOW_SECONDS=15
readonly RUN_END_GUARD_SECONDS=30
readonly PROCESS_KILL_GRACE_SECONDS=5
readonly COVER_DSCP=1
readonly BUSY_SAMPLE_SECONDS=2

target_hosts=()
target_ports=()
target_durations=()
target_results=()
target_normal_seconds=()
target_busy_seconds=()
target_actual_seconds=()

random_between() {
  local min="${1:?min is required}"
  local max="${2:?max is required}"
  local span
  local value

  if [[ "$min" -eq "$max" ]]; then
    printf '%s\n' "$min"
    return 0
  fi

  span=$((max - min + 1))
  value=$(((RANDOM << 16) ^ RANDOM))
  printf '%s\n' "$((min + (value % span)))"
}

now_epoch() {
  date +%s
}

load_targets() {
  local host
  local port

  target_hosts=()
  target_ports=()
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
    target_hosts[i]="${target_hosts[$j]}"
    target_ports[i]="${target_ports[$j]}"
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
  local count="${#target_durations[@]}"
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
  local target_count="${#target_hosts[@]}"
  local remaining
  local index
  local i

  target_durations=()
  remaining="$total_duration"

  for ((i = 0; i < target_count; i++)); do
    target_durations[i]="$MIN_TARGET_WINDOW_SECONDS"
    remaining=$((remaining - MIN_TARGET_WINDOW_SECONDS))
  done

  while ((remaining > 0)); do
    index="$(random_between 0 "$((target_count - 1))")"
    target_durations[index]=$((target_durations[index] + 1))
    remaining=$((remaining - 1))
  done
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

read_tx_bytes() {
  local sys_class_net_root="${RELAY_SYS_CLASS_NET_ROOT:-/sys/class/net}"
  local file="${sys_class_net_root}/$EGRESS_DEV/statistics/tx_bytes"
  local value

  [[ -r "$file" ]] || return 1
  value="$(<"$file")"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

sample_segment_rate() {
  local tx_before
  local tx_after
  local bytes_delta
  local bits_delta
  local tx_rate_bps

  tx_before="$(read_tx_bytes)" || return 1
  sleep "$BUSY_SAMPLE_SECONDS"
  tx_after="$(read_tx_bytes)" || return 1

  uint_ge "$tx_after" "$tx_before" || return 1
  bytes_delta="$((10#$tx_after - 10#$tx_before))"
  bits_delta="$(uint_mul_small "$bytes_delta" 8)" || return 1
  tx_rate_bps="$((10#$bits_delta / BUSY_SAMPLE_SECONDS))"

  if uint_ge "$tx_rate_bps" "$RELAY_BUSY_THRESHOLD_BPS"; then
    SEGMENT_RATE_BPS="$RELAY_BUSY_RATE_BPS"
    SEGMENT_IS_BUSY=1
  else
    SEGMENT_RATE_BPS="$RELAY_COVER_RATE_BPS"
    SEGMENT_IS_BUSY=0
  fi
}

run_iperf3_segment() {
  local protocol="${1:?protocol is required}"
  local host="${2:?host is required}"
  local port="${3:?port is required}"
  local segment_duration="${4:?segment duration is required}"
  local segment_rate_bps="${5:?segment rate is required}"
  local start_epoch
  local end_epoch
  local hard_timeout
  local -a args

  args=(
    -c "$host"
    -p "$port"
    -b "$segment_rate_bps"
    --fq-rate "$segment_rate_bps"
    -t "$segment_duration"
    --bind-dev "$EGRESS_DEV"
    --dscp "$COVER_DSCP"
    --connect-timeout "$CONNECT_TIMEOUT_MS"
  )

  if [[ "$protocol" == "udp" ]]; then
    args=(-u -l 1200 "${args[@]}")
  fi

  hard_timeout=$((segment_duration + PROCESS_KILL_GRACE_SECONDS + 15))
  log "INFO" "segment start iface=$EGRESS_DEV target=$(target_display "$host" "$port") protocol=$protocol planned_seconds=$segment_duration segment_rate_bps=$segment_rate_bps busy=$SEGMENT_IS_BUSY dscp=$COVER_DSCP"
  log "INFO" "segment args: iperf3 ${args[*]}"
  start_epoch="$(now_epoch)"
  if timeout --kill-after="${PROCESS_KILL_GRACE_SECONDS}s" "${hard_timeout}s" iperf3 "${args[@]}"; then
    SEGMENT_EXIT_CODE=0
  else
    SEGMENT_EXIT_CODE=$?
  fi
  end_epoch="$(now_epoch)"
  SEGMENT_ACTUAL_SECONDS=$((end_epoch - start_epoch))
  if ((SEGMENT_ACTUAL_SECONDS < 0)); then
    SEGMENT_ACTUAL_SECONDS=0
  fi
}

sleep_until_deadline() {
  local deadline_epoch="${1:?deadline is required}"
  local delay_seconds="${2:?delay is required}"
  local now
  local remaining
  local actual_sleep

  now="$(now_epoch)"
  remaining=$((deadline_epoch - now))
  if ((remaining <= 0)); then
    return 0
  fi

  actual_sleep="$delay_seconds"
  if ((actual_sleep > remaining)); then
    actual_sleep="$remaining"
  fi

  if ((actual_sleep > 0)); then
    sleep "$actual_sleep"
  fi
}

run_target_window() {
  local index="${1:?target index is required}"
  local host="${target_hosts[$index]}"
  local port="${target_ports[$index]}"
  local window_seconds="${target_durations[$index]}"
  local target_name
  local target_deadline
  local now
  local remaining
  local protocol
  local segment_duration
  local had_success=0
  local used_busy=0
  local fatal_error=0
  local normal_seconds=0
  local busy_seconds=0
  local actual_seconds=0
  local effective_elapsed

  target_name="$(target_display "$host" "$port")"
  target_deadline=$((TARGET_CURSOR_EPOCH + window_seconds))
  TARGET_CURSOR_EPOCH="$target_deadline"

  log "INFO" "target start iface=$EGRESS_DEV target=$target_name planned_window_seconds=$window_seconds deadline_epoch=$target_deadline"

  while :; do
    now="$(now_epoch)"
    remaining=$((target_deadline - now))
    if ((remaining <= 0)); then
      break
    fi

    if ! sample_segment_rate; then
      log "ERROR" "busy sample failed for target=$target_name"
      fatal_error=1
      break
    fi

    now="$(now_epoch)"
    remaining=$((target_deadline - now))
    if ((remaining <= 0)); then
      break
    fi

    segment_duration="$remaining"
    if ((segment_duration > MAX_SEGMENT_SECONDS)); then
      segment_duration="$MAX_SEGMENT_SECONDS"
    fi

    protocol="$(choose_cover_type)"
    run_iperf3_segment "$protocol" "$host" "$port" "$segment_duration" "$SEGMENT_RATE_BPS"

    effective_elapsed="$SEGMENT_ACTUAL_SECONDS"
    if ((effective_elapsed <= 0)); then
      effective_elapsed="$segment_duration"
    fi

    if [[ "$SEGMENT_EXIT_CODE" -eq 0 ]]; then
      had_success=1
      actual_seconds=$((actual_seconds + effective_elapsed))
      if [[ "$SEGMENT_IS_BUSY" -eq 1 ]]; then
        used_busy=1
        busy_seconds=$((busy_seconds + effective_elapsed))
      else
        normal_seconds=$((normal_seconds + effective_elapsed))
      fi
      log "INFO" "segment success iface=$EGRESS_DEV target=$target_name protocol=$protocol planned_seconds=$segment_duration actual_seconds=$effective_elapsed segment_rate_bps=$SEGMENT_RATE_BPS busy=$SEGMENT_IS_BUSY"
    else
      log "WARN" "segment failed iface=$EGRESS_DEV target=$target_name protocol=$protocol planned_seconds=$segment_duration actual_seconds=$effective_elapsed segment_rate_bps=$SEGMENT_RATE_BPS busy=$SEGMENT_IS_BUSY exit_code=$SEGMENT_EXIT_CODE"
      sleep_until_deadline "$target_deadline" "$RETRY_DELAY_SECONDS"
    fi
  done

  if ((fatal_error == 1 || had_success == 0)); then
    target_results[index]="failed"
    RUN_HAS_FAILURE=1
  elif ((used_busy == 1)); then
    target_results[index]="throttled"
  else
    target_results[index]="completed"
  fi

  target_normal_seconds[index]="$normal_seconds"
  target_busy_seconds[index]="$busy_seconds"
  target_actual_seconds[index]="$actual_seconds"
  log "INFO" "target result iface=$EGRESS_DEV target=$target_name result=${target_results[$index]} planned_window_seconds=$window_seconds actual_send_seconds=$actual_seconds normal_rate_seconds=$normal_seconds busy_rate_seconds=$busy_seconds normalized_cover_rate_bps=$RELAY_COVER_RATE_BPS busy_rate_bps=$RELAY_BUSY_RATE_BPS"
}

main() {
  local target_count
  local total_duration
  local delay_seconds
  local max_delay
  local run_start_epoch
  local global_deadline_epoch
  local i

  require_root
  require_cmd date flock ip iperf3 sleep timeout
  require_relay_iperf3_capabilities
  load_and_validate_relay_env "$ENV_FILE" 1
  load_targets

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "INFO" "another cover sender run is already active; exiting"
    exit 0
  fi

  target_count="${#target_hosts[@]}"
  total_duration="$(random_between "$RELAY_DURATION_MIN_SECONDS" "$RELAY_DURATION_MAX_SECONDS")"
  max_delay=$((3600 - RUN_END_GUARD_SECONDS - total_duration))
  if [[ "${RELAY_TEST_FIXED_DELAY_SECONDS:-}" =~ ^[0-9]+$ ]]; then
    delay_seconds="$RELAY_TEST_FIXED_DELAY_SECONDS"
  else
    delay_seconds="$(random_between 0 "$max_delay")"
  fi

  shuffle_targets
  allocate_target_durations "$total_duration"

  run_start_epoch=$(( $(now_epoch) + delay_seconds ))
  global_deadline_epoch=$((run_start_epoch + total_duration))
  TARGET_CURSOR_EPOCH="$run_start_epoch"
  RUN_HAS_FAILURE=0

  log "INFO" "cover sender plan iface=$EGRESS_DEV total_duration_seconds=$total_duration delay_seconds=$delay_seconds cover_rate_bps=$RELAY_COVER_RATE_BPS busy_rate_bps=$RELAY_BUSY_RATE_BPS cover_type=$COVER_TYPE target_count=$target_count global_deadline_epoch=$global_deadline_epoch"
  log "INFO" "cover target order: $(target_order_string)"
  log "INFO" "cover target durations: $(target_duration_string)"

  sleep "$delay_seconds"

  for ((i = 0; i < target_count; i++)); do
    run_target_window "$i"
  done

  for ((i = 0; i < target_count; i++)); do
    log "INFO" "run summary target=$(target_display "${target_hosts[$i]}" "${target_ports[$i]}") result=${target_results[$i]} planned_window_seconds=${target_durations[$i]} actual_send_seconds=${target_actual_seconds[$i]} normal_rate_seconds=${target_normal_seconds[$i]} busy_rate_seconds=${target_busy_seconds[$i]}"
  done

  if [[ "$RUN_HAS_FAILURE" -eq 1 ]]; then
    log "ERROR" "relay cover sender finished with at least one failed target"
    return 1
  fi

  log "INFO" "relay cover sender finished successfully"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
