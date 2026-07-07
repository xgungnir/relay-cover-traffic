#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

# shellcheck source=common/lib.sh
source "$ROOT_DIR/common/lib.sh"
# shellcheck source=relay/cover-sender-hourly.sh
source "$ROOT_DIR/relay/cover-sender-hourly.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

run_test() {
  local name="${1:?test name is required}"
  shift
  TESTS_RUN=$((TESTS_RUN + 1))
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_eq() {
  local expected="${1-}"
  local actual="${2-}"
  local message="${3:?message is required}"
  [[ "$expected" == "$actual" ]] || {
    printf 'assert_eq failed: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    return 1
  }
}

assert_file_contains() {
  local file="${1:?file is required}"
  local pattern="${2:?pattern is required}"
  grep -Fq -- "$pattern" "$file" || {
    printf 'expected %s to contain: %s\n' "$file" "$pattern" >&2
    return 1
  }
}

assert_file_not_contains() {
  local file="${1:?file is required}"
  local pattern="${2:?pattern is required}"
  if grep -Fq -- "$pattern" "$file"; then
    printf 'expected %s not to contain: %s\n' "$file" "$pattern" >&2
    return 1
  fi
}

run_expect_success() {
  "$@" >/dev/null 2>&1
}

run_expect_failure() {
  if "$@" >/dev/null 2>&1; then
    return 1
  fi
}

repo_search_fails() {
  local pattern="${1:?pattern is required}"
  shift

  if command -v rg >/dev/null 2>&1; then
    if rg -n "$pattern" "$@" >/dev/null 2>&1; then
      return 1
    fi
    return 0
  fi

  if grep -R -n -E "$pattern" "$@" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# shellcheck disable=SC2016
validate_relay_env_ok() {
  bash -c 'source "$ROOT_DIR/common/lib.sh"; load_and_validate_relay_env "$1" 0' _ "$1" >/dev/null 2>&1
}

# shellcheck disable=SC2016
validate_relay_env_fail() {
  if bash -c 'source "$ROOT_DIR/common/lib.sh"; load_and_validate_relay_env "$1" 0' _ "$1" >/dev/null 2>&1; then
    return 1
  fi
}

# shellcheck disable=SC2016
validate_relay_env_rate_fields() {
  bash -c 'source "$ROOT_DIR/common/lib.sh"; load_and_validate_relay_env "$1" 0; [[ "$RELAY_COVER_RATE_BPS" == "$2" && "$RELAY_BUSY_RATE_BPS" == "$3" ]]' _ "$1" "$2" "$3" >/dev/null 2>&1
}

make_valid_relay_env() {
  local file="${1:?file is required}"
  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, [2001:db8::20]:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="auto"
ENV
}

write_mock_systemctl() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${MOCK_SYSTEMCTL_STATE_DIR:?}"
mkdir -p "$state_dir/enabled" "$state_dir/active" "$state_dir/logs" "$state_dir/cat"
printf '%s\n' "$*" >>"$state_dir/logs/commands.log"

is_active() {
  [[ -f "$state_dir/active/$1" ]]
}

is_enabled() {
  [[ -f "$state_dir/enabled/$1" ]]
}

set_active() {
  : >"$state_dir/active/$1"
}

clear_active() {
  rm -f "$state_dir/active/$1"
}

set_enabled() {
  : >"$state_dir/enabled/$1"
}

clear_enabled() {
  rm -f "$state_dir/enabled/$1"
}

collect_units() {
  UNITS=()
  while (($# > 0)); do
    case "$1" in
      --now|--no-block)
        ;;
      *)
        UNITS+=("$1")
        ;;
    esac
    shift
  done
}

cmd="${1:-}"
shift || true
case "$cmd" in
  cat)
    unit="${1:?unit is required}"
    if [[ -f "$state_dir/cat/$unit" ]]; then
      cat "$state_dir/cat/$unit"
      exit 0
    fi
    exit 1
    ;;
  show)
    unit="${1:?unit is required}"
    shift
    if [[ "${1:-}" == "-p" && "${3:-}" == "--value" ]]; then
      case "${2:-}" in
        ActiveState)
          if is_active "$unit"; then
            printf 'active\n'
          else
            printf 'inactive\n'
          fi
          exit 0
          ;;
        ActiveEnterTimestamp)
          if is_active "$unit"; then
            printf 'Mon 2026-01-01 00:00:00 UTC\n'
          else
            printf 'n/a\n'
          fi
          exit 0
          ;;
      esac
    fi
    exit 0
    ;;
  is-enabled)
    unit="${1:?unit is required}"
    if is_enabled "$unit"; then
      printf 'enabled\n'
      exit 0
    fi
    printf 'disabled\n'
    exit 1
    ;;
  enable)
    collect_units "$@"
    for unit in "${UNITS[@]}"; do
      set_enabled "$unit"
      if [[ " $* " == *" --now "* ]]; then
        set_active "$unit"
      fi
    done
    ;;
  disable)
    collect_units "$@"
    for unit in "${UNITS[@]}"; do
      clear_enabled "$unit"
      if [[ " $* " == *" --now "* ]]; then
        clear_active "$unit"
      fi
    done
    ;;
  start)
    collect_units "$@"
    for unit in "${UNITS[@]}"; do
      set_active "$unit"
    done
    ;;
  stop)
    collect_units "$@"
    for unit in "${UNITS[@]}"; do
      clear_active "$unit"
    done
    ;;
  daemon-reload|reset-failed|list-timers|status)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
MOCK
  chmod +x "$path"
}

write_mock_apt_get() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${MOCK_APT_LOG:?}"
MOCK
  chmod +x "$path"
}

write_mock_ip() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "link" && "${2:-}" == "show" && "${3:-}" == "dev" ]]; then
  if [[ "${4:-}" == "${MOCK_IP_VALID_DEV:-test0}" ]]; then
    printf '2: %s: <UP>\n' "${4:-}"
    exit 0
  fi
  exit 1
fi
printf 'mock ip only implements: ip link show dev <dev>\n' >&2
exit 1
MOCK
  chmod +x "$path"
}

write_mock_iperf3_install() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: iperf3 [options]
  --bind-dev
  --dscp
  --fq-rate
HELP
  exit 0
fi
if [[ "${1:-}" == "--version" ]]; then
  printf 'iperf 3.15\n'
  exit 0
fi
printf 'iperf3 install mock should not be used for runtime sender traffic\n' >&2
exit 0
MOCK
  chmod +x "$path"
}

write_mock_date() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
clock_file="${MOCK_CLOCK_FILE:?}"
clock="$(<"$clock_file")"
case "${1:-}" in
  +%s)
    printf '%s\n' "$clock"
    ;;
  -Is)
    printf '2026-01-01T00:00:%02d+0000\n' "$clock"
    ;;
  *)
    /bin/date "$@"
    ;;
esac
MOCK
  chmod +x "$path"
}

write_mock_sleep() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
clock_file="${MOCK_CLOCK_FILE:?}"
tx_file="${MOCK_TX_FILE:-}"
sequence_file="${MOCK_TX_SEQUENCE_FILE:-}"
seconds="${1:-0}"
clock="$(<"$clock_file")"
printf '%s\n' "$((clock + seconds))" >"$clock_file"
if ((seconds > 0)) && [[ -n "$tx_file" && -n "$sequence_file" && -s "$sequence_file" ]]; then
  next_value="$(head -n 1 "$sequence_file")"
  tail -n +2 "$sequence_file" >"${sequence_file}.tmp" || true
  mv "${sequence_file}.tmp" "$sequence_file"
  printf '%s\n' "$next_value" >"$tx_file"
fi
MOCK
  chmod +x "$path"
}

write_mock_timeout() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
while (($# > 0)); do
  case "$1" in
    --kill-after=*)
      shift
      ;;
    *s)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done
"$@"
MOCK
  chmod +x "$path"
}

write_mock_flock() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
MOCK
  chmod +x "$path"
}

write_mock_iperf3_sender() {
  local path="${1:?path is required}"
  cat >"$path" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == "--help" ]]; then
  cat <<'HELP'
Usage: iperf3 [options]
  --bind-dev
  --dscp
  --fq-rate
HELP
  exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
  printf 'iperf 3.15\n'
  exit 0
fi

clock_file="${MOCK_CLOCK_FILE:?}"
log_file="${MOCK_IPERF3_LOG:?}"
host=""
rate=""
fq_rate=""
dscp=""
bind_dev=""
duration="0"
protocol="tcp"

while (($# > 0)); do
  case "$1" in
    -c)
      host="$2"
      shift 2
      ;;
    -b)
      rate="$2"
      shift 2
      ;;
    --fq-rate)
      fq_rate="$2"
      shift 2
      ;;
    --dscp)
      dscp="$2"
      shift 2
      ;;
    --bind-dev)
      bind_dev="$2"
      shift 2
      ;;
    -t)
      duration="$2"
      shift 2
      ;;
    -u)
      protocol="udp"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

clock="$(<"$clock_file")"
printf '%s start host=%s protocol=%s rate=%s fq_rate=%s dscp=%s bind_dev=%s duration=%s\n' \
  "$clock" "$host" "$protocol" "$rate" "$fq_rate" "$dscp" "$bind_dev" "$duration" >>"$log_file"
printf '%s\n' "$((clock + duration))" >"$clock_file"
clock="$(<"$clock_file")"
printf '%s end host=%s\n' "$clock" "$host" >>"$log_file"

if [[ "$host" == fail.example.com ]]; then
  exit 1
fi
MOCK
  chmod +x "$path"
}

make_lifecycle_mock_env() {
  local dir="${1:?dir is required}"
  local mock_bin="$dir/mock-bin"

  mkdir -p "$mock_bin"
  write_mock_systemctl "$mock_bin/systemctl"
  write_mock_apt_get "$mock_bin/apt-get"
  write_mock_ip "$mock_bin/ip"
  write_mock_iperf3_install "$mock_bin/iperf3"
  printf '' >"$dir/apt.log"

  export MOCK_SYSTEMCTL_STATE_DIR="$dir/systemctl"
  export MOCK_APT_LOG="$dir/apt.log"
  export MOCK_IP_VALID_DEV="test0"
  export PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

make_sender_mock_env() {
  local dir="${1:?dir is required}"
  local mock_bin="$dir/mock-bin"

  mkdir -p "$mock_bin"
  write_mock_ip "$mock_bin/ip"
  write_mock_date "$mock_bin/date"
  write_mock_sleep "$mock_bin/sleep"
  write_mock_timeout "$mock_bin/timeout"
  write_mock_flock "$mock_bin/flock"
  write_mock_iperf3_sender "$mock_bin/iperf3"
  export MOCK_IP_VALID_DEV="test0"
  export MOCK_CLOCK_FILE="$dir/clock"
  export MOCK_IPERF3_LOG="$dir/iperf3.log"
  printf '0\n' >"$dir/clock"
  : >"$dir/iperf3.log"
  export PATH="$mock_bin:/usr/bin:/bin:/usr/sbin:/sbin"
}

test_relay_parser_matrix() {
  local dir="$TEST_TMP_ROOT/parser"
  local file="$dir/relay.env"
  local legacy

  mkdir -p "$dir"

  cat >"$file" <<'ENV'
# comment
COVER_TYPE="auto"

COVER_DURATION_RANGE="1200-2400"
COVER_RATE="2M"
COVER_TARGETS="one.example.com:11222, [2001:db8::20]:11222"
EGRESS_DEV="test0"
ENV
  validate_relay_env_ok "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
EGRESS_DEV="test1"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
EXTRA_FIELD="bad"
ENV
  validate_relay_env_fail "$file" || return 1

  for legacy in "${RELAY_ENV_LEGACY_FIELDS[@]}"; do
    cat >"$file" <<ENV
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
${legacy}="legacy"
ENV
    validate_relay_env_fail "$file" || return 1
  done

  cat >"$file" <<'ENV'
EGRESS_DEV=test0
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="$(printf test0)"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="`printf test0`"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"; echo bad
COVER_TARGETS="one.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS=""
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:0"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
  COVER_TARGETS="one.example.com:11222, one.example.com:11222"
  COVER_RATE="2M"
  COVER_DURATION_RANGE="1200-2400"
  COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1
}

test_rate_and_duration_matrix() {
  local dir="$TEST_TMP_ROOT/rate-duration"
  local file="$dir/relay.env"

  mkdir -p "$dir"

  assert_eq "1" "$(rate_to_bps 1)" "rate 1" || return 1
  assert_eq "64000" "$(rate_to_bps 64K)" "rate 64K" || return 1
  assert_eq "2000000" "$(rate_to_bps 2M)" "rate 2M" || return 1
  assert_eq "5000000" "$(rate_to_bps 5M)" "rate 5M" || return 1
  assert_eq "6000000" "$(rate_to_bps 6M)" "rate 6M" || return 1
  assert_eq "20000000" "$(rate_to_bps 20M)" "rate 20M" || return 1
  assert_eq "5000000" "$(rate_to_bps 5000000)" "rate 5000000" || return 1

  ! rate_to_bps 0 >/dev/null 2>&1 || return 1
  ! rate_to_bps 5.1M >/dev/null 2>&1 || return 1
  ! rate_to_bps 9223372036854775808 >/dev/null 2>&1 || return 1
  ! rate_to_bps 5T >/dev/null 2>&1 || return 1
  ! rate_to_bps '2 M' >/dev/null 2>&1 || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="6M"
COVER_DURATION_RANGE="30-30"
COVER_TYPE="udp"
ENV
  validate_relay_env_rate_fields "$file" "6000000" "1500000" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="30-30"
COVER_TYPE="tcp"
ENV
  validate_relay_env_ok "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="45-45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_ok "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="46-45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="0-45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="-1-45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="30 -45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="30-"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="30-3571"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1

  cat >"$file" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="29-45"
COVER_TYPE="tcp"
ENV
  validate_relay_env_fail "$file" || return 1
}

test_duration_allocation() {
  local sum
  local value
  local i
  target_hosts=(one two three)
  target_ports=(1 2 3)

  for ((i = 0; i < 20; i++)); do
    allocate_target_durations 90
    sum=0
    for value in "${target_durations[@]}"; do
      ((value >= 15)) || return 1
      sum=$((sum + value))
    done
    assert_eq "90" "$sum" "duration allocation sum" || return 1
  done
}

test_install_preflight_no_side_effect() {
  local dir="$TEST_TMP_ROOT/install-preflight"
  local candidate="$dir/config/relay.env"
  local runtime="$dir/etc/relay.env"

  mkdir -p "$dir/config"
  make_lifecycle_mock_env "$dir"
  cat >"$candidate" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="0"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="auto"
ENV

  if env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_SKIP_STATUS=1 \
    RELAY_TEST_SKIP_OS_CHECK=1 \
    RELAY_CANDIDATE_ENV_FILE="$candidate" \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/install.sh" >/dev/null 2>&1; then
    return 1
  fi

  [[ ! -e "$runtime" ]] || return 1
  [[ ! -s "$dir/apt.log" ]] || return 1
  [[ ! -s "$dir/systemctl/logs/commands.log" ]] || return 1
}

test_install_idempotent_and_units() {
  local dir="$TEST_TMP_ROOT/install-idempotent"
  local candidate="$dir/config/relay.env"
  local runtime="$dir/etc/relay.env"
  local service_file="$dir/systemd/relay-cover-sender.service"
  local timer_file="$dir/systemd/relay-cover-sender.timer"
  local installed_script="$dir/usr/local/sbin/relay-cover-sender-hourly.sh"
  local installed_lib="$dir/usr/local/lib/relay-cover-traffic/lib.sh"

  mkdir -p "$dir/config" "$dir/systemd" "$dir/usr/local/sbin" "$dir/usr/local/lib/relay-cover-traffic"
  make_lifecycle_mock_env "$dir"
  make_valid_relay_env "$candidate"

  env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_SKIP_STATUS=1 \
    RELAY_TEST_SKIP_OS_CHECK=1 \
    RELAY_CANDIDATE_ENV_FILE="$candidate" \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    RELAY_SENDER_SERVICE_FILE="$service_file" \
    RELAY_SENDER_TIMER_FILE="$timer_file" \
    RELAY_SENDER_INSTALLED_SCRIPT="$installed_script" \
    RELAY_SENDER_INSTALLED_LIB="$installed_lib" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/install.sh" >/dev/null

  env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_SKIP_STATUS=1 \
    RELAY_TEST_SKIP_OS_CHECK=1 \
    RELAY_CANDIDATE_ENV_FILE="$candidate" \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    RELAY_SENDER_SERVICE_FILE="$service_file" \
    RELAY_SENDER_TIMER_FILE="$timer_file" \
    RELAY_SENDER_INSTALLED_SCRIPT="$installed_script" \
    RELAY_SENDER_INSTALLED_LIB="$installed_lib" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/install.sh" >/dev/null

  assert_file_contains "$service_file" "After=network-online.target" || return 1
  assert_file_not_contains "$service_file" "relay-cover-qos.service" || return 1
  assert_file_contains "$service_file" "RuntimeMaxSec=3600" || return 1
  assert_file_contains "$timer_file" "OnCalendar=hourly" || return 1
  assert_file_contains "$timer_file" "Persistent=true" || return 1
  [[ -f "$installed_script" ]] || return 1
  [[ -f "$installed_lib" ]] || return 1
  [[ ! -e "$dir/systemd/relay-cover-qos.service" ]] || return 1
  assert_file_not_contains "$dir/systemctl/logs/commands.log" "sing-box" || return 1
}

test_apply_invalid_no_stop() {
  local dir="$TEST_TMP_ROOT/apply-invalid"
  local candidate="$dir/config/relay.env"
  local runtime="$dir/etc/relay.env"
  local log_file="$dir/systemctl/logs/commands.log"

  mkdir -p "$dir/config" "$dir/etc"
  make_lifecycle_mock_env "$dir"
  make_valid_relay_env "$runtime"
  cat >"$candidate" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222"
COVER_RATE="5.1M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  mkdir -p "$dir/systemctl/enabled" "$dir/systemctl/active"
  : >"$dir/systemctl/enabled/relay-cover-sender.timer"
  : >"$dir/systemctl/active/relay-cover-sender.timer"
  : >"$dir/systemctl/active/relay-cover-sender.service"

  if env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_CANDIDATE_ENV_FILE="$candidate" \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/apply-env.sh" >/dev/null 2>&1; then
    return 1
  fi

  [[ ! -s "$log_file" ]] || return 1
}

test_apply_rollback() {
  local dir="$TEST_TMP_ROOT/apply-rollback"
  local candidate="$dir/config/relay.env"
  local runtime="$dir/etc/relay.env"
  local service_file="$dir/systemd/relay-cover-sender.service"
  local timer_file="$dir/systemd/relay-cover-sender.timer"
  local installed_script="$dir/usr/local/sbin/relay-cover-sender-hourly.sh"
  local installed_lib="$dir/usr/local/lib/relay-cover-traffic/lib.sh"

  mkdir -p "$dir/config" "$dir/etc" "$dir/systemd" "$dir/usr/local/sbin" "$dir/usr/local/lib/relay-cover-traffic"
  make_lifecycle_mock_env "$dir"
  make_valid_relay_env "$candidate"
  cat >"$runtime" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="old.example.com:11222"
COVER_RATE="2M"
COVER_DURATION_RANGE="1200-2400"
COVER_TYPE="tcp"
ENV
  printf 'old service\n' >"$service_file"
  printf 'old timer\n' >"$timer_file"
  printf 'old script\n' >"$installed_script"
  printf 'old lib\n' >"$installed_lib"
  mkdir -p "$dir/systemctl/enabled" "$dir/systemctl/active"
  : >"$dir/systemctl/enabled/relay-cover-sender.timer"
  : >"$dir/systemctl/active/relay-cover-sender.timer"
  : >"$dir/systemctl/active/relay-cover-sender.service"

  if env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_FORCE_INSTALL_COVER_SENDER_FAIL=1 \
    RELAY_CANDIDATE_ENV_FILE="$candidate" \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    RELAY_SENDER_SERVICE_FILE="$service_file" \
    RELAY_SENDER_TIMER_FILE="$timer_file" \
    RELAY_SENDER_INSTALLED_SCRIPT="$installed_script" \
    RELAY_SENDER_INSTALLED_LIB="$installed_lib" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/apply-env.sh" >/dev/null 2>&1; then
    return 1
  fi

  assert_file_contains "$runtime" 'old.example.com:11222' || return 1
  assert_file_contains "$service_file" 'old service' || return 1
  assert_file_contains "$timer_file" 'old timer' || return 1
  assert_file_contains "$installed_script" 'old script' || return 1
  assert_file_contains "$installed_lib" 'old lib' || return 1
  [[ -f "$dir/systemctl/enabled/relay-cover-sender.timer" ]] || return 1
  [[ -f "$dir/systemctl/active/relay-cover-sender.timer" ]] || return 1
  [[ -f "$dir/systemctl/active/relay-cover-sender.service" ]] || return 1
}

run_sender_case() {
  local case_dir="${1:?case dir is required}"
  local host="${2:?host is required}"
  local rate="${3:?rate is required}"
  local duration_range="${4:?duration is required}"
  local tx_sequence="${5:?tx sequence is required}"
  local cover_type="${6:?cover type is required}"
  local expected_exit="${7:?expected exit is required}"

  local runtime="$case_dir/relay.env"
  local tx_root="$case_dir/sys/class/net/test0/statistics"

  mkdir -p "$tx_root"
  printf '0\n' >"$tx_root/tx_bytes"
  printf '%s\n' "$tx_sequence" >"$case_dir/tx-seq.txt"
  cat >"$runtime" <<ENV
EGRESS_DEV="test0"
COVER_TARGETS="${host}:11222"
COVER_RATE="${rate}"
COVER_DURATION_RANGE="${duration_range}"
COVER_TYPE="${cover_type}"
ENV

  export MOCK_TX_FILE="$tx_root/tx_bytes"
  export MOCK_TX_SEQUENCE_FILE="$case_dir/tx-seq.txt"

  if env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_FIXED_DELAY_SECONDS=0 \
    RELAY_RUNTIME_ENV_FILE="$runtime" \
    RELAY_SYS_CLASS_NET_ROOT="$case_dir/sys/class/net" \
    RELAY_SENDER_LOCK_FILE="$case_dir/relay.lock" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/cover-sender-hourly.sh" >/dev/null 2>&1; then
    actual_exit=0
  else
    actual_exit=$?
  fi

  assert_eq "$expected_exit" "$actual_exit" "sender exit code" || return 1
}

test_sender_runtime_matrix() {
  local dir="$TEST_TMP_ROOT/sender"
  local multi_runtime="$dir/multi.env"
  local multi_tx_root="$dir/multi-sys/class/net/test0/statistics"
  local first_start
  local second_start

  mkdir -p "$dir"
  make_sender_mock_env "$dir"

  run_sender_case "$dir/completed" "ok.example.com" "100" "15-15" "10" "tcp" "0" || return 1
  assert_file_contains "$dir/iperf3.log" "rate=100 fq_rate=100 dscp=1 bind_dev=test0" || return 1

  : >"$dir/iperf3.log"
  printf '0\n' >"$dir/clock"
  run_sender_case "$dir/throttled" "ok.example.com" "100" "15-15" "25" "udp" "0" || return 1
  assert_file_contains "$dir/iperf3.log" "protocol=udp rate=25 fq_rate=25 dscp=1 bind_dev=test0" || return 1

  : >"$dir/iperf3.log"
  printf '0\n' >"$dir/clock"
  run_sender_case "$dir/failed" "fail.example.com" "100" "15-15" "10" "tcp" "1" || return 1
  assert_file_contains "$dir/iperf3.log" "host=fail.example.com" || return 1

  : >"$dir/iperf3.log"
  printf '0\n' >"$dir/clock"
  mkdir -p "$multi_tx_root"
  printf '0\n' >"$multi_tx_root/tx_bytes"
  printf '10\n20\n' >"$dir/multi-tx.txt"
  cat >"$multi_runtime" <<'ENV'
EGRESS_DEV="test0"
COVER_TARGETS="one.example.com:11222, two.example.com:11222"
COVER_RATE="100"
COVER_DURATION_RANGE="30-30"
COVER_TYPE="tcp"
ENV
  export MOCK_TX_FILE="$multi_tx_root/tx_bytes"
  export MOCK_TX_SEQUENCE_FILE="$dir/multi-tx.txt"
  env \
    RELAY_TEST_ALLOW_NON_ROOT=1 \
    RELAY_TEST_FIXED_DELAY_SECONDS=0 \
    RELAY_RUNTIME_ENV_FILE="$multi_runtime" \
    RELAY_SYS_CLASS_NET_ROOT="$dir/multi-sys/class/net" \
    RELAY_SENDER_LOCK_FILE="$dir/multi.lock" \
    PATH="$PATH" \
    bash "$ROOT_DIR/relay/cover-sender-hourly.sh" >/dev/null

  first_start="$(awk 'NR==1 {print $1}' "$dir/iperf3.log")"
  second_start="$(awk 'NR==3 {print $1}' "$dir/iperf3.log")"
  ((second_start >= first_start + 13)) || return 1
}

test_static_repo_checks() {
  repo_search_fails 'RELAY_QOS_TARGETS|COVER_MIN_SECONDS|COVER_MAX_SECONDS|ALLOW_COVER_RATE_ABOVE_5M|TC_TOTAL_RATE|TC_RELAY_RATE|TC_RELAY_CEIL|TC_COVER_RATE|TC_COVER_CEIL|TC_DEFAULT_RATE|TC_DEFAULT_CEIL' \
    "$ROOT_DIR/relay" "$ROOT_DIR/config/relay.env.example" "$ROOT_DIR/README.md" || return 1

  repo_search_fails 'relay-cover-qos\.service|tc qdisc|setup-sb-service|systemctl (enable|disable|start|stop|restart).*sing-box|sing-box\.service' \
    "$ROOT_DIR/relay" || return 1
}

main() {
  run_test "relay parser matrix" test_relay_parser_matrix
  run_test "rate and duration matrix" test_rate_and_duration_matrix
  run_test "duration allocation" test_duration_allocation
  run_test "install preflight has no side effect" test_install_preflight_no_side_effect
  run_test "install idempotent and unit content" test_install_idempotent_and_units
  run_test "apply invalid config does not stop services" test_apply_invalid_no_stop
  run_test "apply rollback restores runtime and assets" test_apply_rollback
  run_test "sender runtime matrix" test_sender_runtime_matrix
  run_test "static repo checks" test_static_repo_checks

  printf '%s tests run, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}

main "$@"
