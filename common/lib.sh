#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -n "${RELAY_COMMON_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly RELAY_COMMON_LIB_LOADED=1

readonly RELAY_ENV_ALLOWED_FIELDS=(
  EGRESS_DEV
  COVER_TARGETS
  COVER_RATE
  COVER_DURATION_RANGE
  COVER_TYPE
)
readonly RELAY_ENV_LEGACY_FIELDS=(
  RELAY_QOS_TARGETS
  COVER_MIN_SECONDS
  COVER_MAX_SECONDS
  COVER_RETRY_DELAY_SECONDS
  COVER_MAX_SEGMENT_SECONDS
  ALLOW_COVER_RATE_ABOVE_5M
  TC_TOTAL_RATE
  TC_RELAY_RATE
  TC_RELAY_CEIL
  TC_COVER_RATE
  TC_COVER_CEIL
  TC_DEFAULT_RATE
  TC_DEFAULT_CEIL
)
readonly RELAY_ENV_UINT64_MAX="9223372036854775807"
readonly RELAY_BUSY_RATE_DIVISOR=4

log() {
  local level="INFO"
  local ts
  if [[ $# -gt 1 ]]; then
    level="$1"
    shift
  fi

  ts="$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  printf '[%s] [%s] %s\n' "$ts" "$level" "$*" >&2
}

die() {
  log "ERROR" "$*"
  exit 1
}

require_root() {
  if [[ "${RELAY_TEST_ALLOW_NON_ROOT:-0}" == "1" ]]; then
    return 0
  fi

  [[ ${EUID} -eq 0 ]] || die "this script must be run as root"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

require_env() {
  local name
  for name in "$@"; do
    if [[ "${!name+x}" != "x" || -z "${!name}" ]]; then
      die "required env var is unset or empty: $name"
    fi
  done
}

load_env_file() {
  local env_file="${1:?env file path is required}"

  [[ -f "$env_file" ]] || die "env file not found: $env_file"

  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

require_config_env_file() {
  local env_file="${1:?config env path is required}"
  local example_file="${2:-}"

  if [[ -f "$env_file" ]]; then
    return 0
  fi

  if [[ -n "$example_file" ]]; then
    die "required config env file not found: $env_file; create it from $example_file, edit it, then rerun this script"
  fi

  die "required config env file not found: $env_file"
}

sync_runtime_env_file() {
  local src="${1:?source env path is required}"
  local dest="${2:?runtime env path is required}"

  require_config_env_file "$src"
  command -v install >/dev/null 2>&1 || die "required command not found: install"

  install -d -m 0755 "${dest%/*}"
  install -m 0600 "$src" "$dest"
  log "INFO" "synced env from $src to $dest"
}

install_file() {
  local src="${1:?source path is required}"
  local dest="${2:?destination path is required}"
  local mode="${3:-0755}"

  [[ -f "$src" ]] || die "source file not found: $src"
  install -d -m 0755 "${dest%/*}"
  install -m "$mode" "$src" "$dest"
}

backup_file_if_exists() {
  local src="${1:?source path is required}"
  local dest="${2:?backup path is required}"

  if [[ -e "$src" ]]; then
    install -D -m 0600 "$src" "$dest"
    return 0
  fi

  return 1
}

restore_file_or_remove() {
  local backup="${1:?backup path is required}"
  local dest="${2:?destination path is required}"

  if [[ -e "$backup" ]]; then
    install -D -m 0600 "$backup" "$dest"
  else
    rm -f "$dest"
  fi
}

install_private_file_atomically() {
  local src="${1:?source path is required}"
  local dest="${2:?destination path is required}"
  local tmp

  [[ -f "$src" ]] || die "source file not found: $src"
  install -d -m 0755 "${dest%/*}"
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  install -m 0600 "$src" "$tmp"
  mv -f "$tmp" "$dest"
}

filter_known_iperf3_install_noise() {
  sed \
    -e '/^\/usr\/bin\/deb-systemd-helper was not called from dpkg\. Exiting\.$/d' \
    -e '/^Failed to stop iperf3\.service: Unit iperf3\.service not loaded\.$/d'
}

apt_get_install() {
  require_cmd apt-get sed

  apt-get install -y "$@" 2>&1 | filter_known_iperf3_install_noise
}

disable_default_iperf3_service() {
  require_cmd systemctl sed

  systemctl disable --now iperf3 2>&1 | filter_known_iperf3_install_noise || true
}

is_positive_int() {
  local value="${1:-}"
  [[ "$value" =~ ^[1-9][0-9]*$ ]]
}

trim() {
  local value="${1:-}"

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

validate_port() {
  local port="${1:-}"

  is_positive_int "$port" || return 1
  ((10#$port <= 65535))
}

is_ipv4_literal() {
  local ip="${1:-}"
  local IFS=.
  local -a octets
  local octet

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<<"$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_ipv6_literal() {
  local ip="${1:-}"

  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
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

parse_host_port() {
  local raw="${1:?target is required}"

  TARGET_HOST=""
  TARGET_PORT=""

  if [[ "$raw" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    TARGET_HOST="${BASH_REMATCH[1]}"
    TARGET_PORT="${BASH_REMATCH[2]}"
    is_ipv6_literal "$TARGET_HOST" || die "invalid IPv6 target host: $raw"
  elif [[ "$raw" =~ ^([^][[:space:]:,]+):([0-9]+)$ ]]; then
    TARGET_HOST="${BASH_REMATCH[1]}"
    TARGET_PORT="${BASH_REMATCH[2]}"
  else
    die "invalid target '$raw'; expected host:port or [ipv6]:port"
  fi

  validate_port "$TARGET_PORT" || die "invalid target port in '$raw': $TARGET_PORT"
}

parse_target_list() {
  local raw="${1:?target list is required}"
  local item
  local canonical
  local count=0
  local seen="|"

  while IFS= read -r item; do
    item="$(trim "$item")"
    [[ -n "$item" ]] || die "target list contains an empty target"

    parse_host_port "$item"
    canonical="$(target_display "$TARGET_HOST" "$TARGET_PORT")"
    [[ "$seen" != *"|$canonical|"* ]] || die "duplicate target is not allowed: $canonical"
    seen="${seen}${canonical}|"
    printf '%s\t%s\n' "$TARGET_HOST" "$TARGET_PORT"
    count=$((count + 1))
  done < <(printf '%s\n' "$raw" | tr ',' '\n')

  [[ "$count" -gt 0 ]] || die "target list is empty"
}

uint_normalize() {
  local value="${1:?value is required}"

  while [[ "$value" == 0* && "$value" != "0" ]]; do
    value="${value#0}"
  done
  if [[ -z "$value" ]]; then
    printf '0\n'
  else
    printf '%s\n' "$value"
  fi
}

uint_compare() {
  local left
  local right

  left="$(uint_normalize "${1:?left value is required}")"
  right="$(uint_normalize "${2:?right value is required}")"

  if ((${#left} > ${#right})); then
    printf '1\n'
  elif ((${#left} < ${#right})); then
    printf '%s\n' "-1"
  elif [[ "$left" > "$right" ]]; then
    printf '1\n'
  elif [[ "$left" < "$right" ]]; then
    printf '%s\n' "-1"
  else
    printf '0\n'
  fi
}

uint_gt() {
  [[ "$(uint_compare "${1:?}" "${2:?}")" == "1" ]]
}

uint_lt() {
  [[ "$(uint_compare "${1:?}" "${2:?}")" == "-1" ]]
}

uint_ge() {
  local cmp
  cmp="$(uint_compare "${1:?}" "${2:?}")"
  [[ "$cmp" == "0" || "$cmp" == "1" ]]
}

uint_le() {
  local cmp
  cmp="$(uint_compare "${1:?}" "${2:?}")"
  [[ "$cmp" == "0" || "$cmp" == "-1" ]]
}

uint_mul_small() {
  local value="${1:?value is required}"
  local factor="${2:?factor is required}"
  local limit

  is_positive_int "$value" || [[ "$value" == "0" ]] || return 1
  is_positive_int "$factor" || return 1

  limit="$((10#${RELAY_ENV_UINT64_MAX} / factor))"
  uint_le "$value" "$limit" || return 1
  printf '%s\n' "$((10#$value * factor))"
}

uint_div_ceil_small() {
  local value="${1:?value is required}"
  local divisor="${2:?divisor is required}"
  local quotient
  local remainder

  is_positive_int "$value" || return 1
  is_positive_int "$divisor" || return 1

  quotient="$((10#$value / divisor))"
  remainder="$((10#$value % divisor))"
  if ((remainder > 0)); then
    quotient=$((quotient + 1))
  fi

  printf '%s\n' "$quotient"
}

rate_to_bps() {
  local raw="${1:?rate is required}"
  local number=""
  local suffix=""
  local factor=1

  [[ "$raw" =~ ^([1-9][0-9]*)([KMG]?)$ ]] || return 1
  number="${BASH_REMATCH[1]}"
  suffix="${BASH_REMATCH[2]}"

  case "$suffix" in
    "") factor=1 ;;
    K) factor=1000 ;;
    M) factor=1000000 ;;
    G) factor=1000000000 ;;
    *) return 1 ;;
  esac

  uint_mul_small "$number" "$factor"
}

require_no_control_chars() {
  local value="${1-}"
  [[ "$value" =~ [[:cntrl:]] ]] && return 1
  return 0
}

relay_env_value_is_safe() {
  local value="${1-}"

  [[ "$value" != *'$'* ]] || return 1
  [[ "$value" != *'`'* ]] || return 1
  [[ "$value" != *\\* ]] || return 1
}

relay_env_field_kind() {
  local key="${1:?key is required}"
  local name

  for name in "${RELAY_ENV_ALLOWED_FIELDS[@]}"; do
    if [[ "$key" == "$name" ]]; then
      printf 'allowed\n'
      return 0
    fi
  done

  for name in "${RELAY_ENV_LEGACY_FIELDS[@]}"; do
    if [[ "$key" == "$name" ]]; then
      printf 'legacy\n'
      return 0
    fi
  done

  printf 'unknown\n'
}

unset_relay_env_fields() {
  local key
  for key in "${RELAY_ENV_ALLOWED_FIELDS[@]}"; do
    unset "$key" || true
  done
}

load_relay_env_file() {
  local env_file="${1:?relay env path is required}"
  local line
  local line_number=0
  local key=""
  local value=""
  local kind=""
  local raw_value=""
  local seen="|"

  [[ -f "$env_file" ]] || die "relay env file not found: $env_file"
  unset_relay_env_fields

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))

    require_no_control_chars "$line" || die "invalid relay env line ${line_number}: control characters are not allowed"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    [[ "$line" == *=* ]] || die "invalid relay env syntax at line ${line_number}; expected KEY=\"value\" with no extra spaces or shell syntax"
    key="${line%%=*}"
    raw_value="${line#*=}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid relay env syntax at line ${line_number}; expected KEY=\"value\" with no extra spaces or shell syntax"
    [[ "$raw_value" =~ ^\"[^\"]*\"$ ]] || die "invalid relay env syntax at line ${line_number}; expected KEY=\"value\" with no extra spaces or shell syntax"
    value="${raw_value#\"}"
    value="${value%\"}"
    kind="$(relay_env_field_kind "$key")"

    [[ "$seen" != *"|$key|"* ]] || die "duplicate relay env field is not allowed: $key"
    seen="${seen}${key}|"

    case "$kind" in
      allowed)
        require_no_control_chars "$value" || die "invalid relay env value for $key: control characters are not allowed"
        relay_env_value_is_safe "$value" || die "invalid relay env value for $key: shell-style escaping and substitution are not allowed"
        printf -v "$key" '%s' "$value"
        ;;
      legacy)
        die "legacy relay env field is not supported: $key; use config/relay.env.example as the new format baseline"
        ;;
      *)
        die "unknown relay env field: $key; use config/relay.env.example as the new format baseline"
        ;;
    esac
  done <"$env_file"
}

validate_interface_name() {
  local dev="${1:?device name is required}"

  [[ "$dev" =~ ^[[:alnum:]_.:-]+$ ]] || return 1
}

validate_relay_egress_dev() {
  local require_existing="${1:-1}"

  [[ -n "${EGRESS_DEV:-}" ]] || die "EGRESS_DEV must not be empty"
  validate_interface_name "$EGRESS_DEV" || die "EGRESS_DEV contains unsupported characters: $EGRESS_DEV"

  if [[ "$require_existing" == "1" ]]; then
    require_cmd ip
    ip link show dev "$EGRESS_DEV" >/dev/null 2>&1 || die "EGRESS_DEV does not exist: $EGRESS_DEV"
  fi
}

validate_relay_cover_targets() {
  local target_count=0
  local line
  local parsed_targets
  local _host
  local _port

  [[ -n "${COVER_TARGETS:-}" ]] || die "COVER_TARGETS must not be empty"
  parsed_targets="$(parse_target_list "$COVER_TARGETS")" || die "invalid COVER_TARGETS: $COVER_TARGETS"

  while IFS= read -r line; do
    IFS=$'\t' read -r _host _port <<<"$line"
    target_count=$((target_count + 1))
  done <<<"$parsed_targets"

  [[ "$target_count" -gt 0 ]] || die "COVER_TARGETS must contain at least one target"
  RELAY_VALIDATED_TARGET_COUNT="$target_count"
}

validate_relay_cover_rate() {
  local bps

  [[ -n "${COVER_RATE:-}" ]] || die "COVER_RATE must not be empty"
  bps="$(rate_to_bps "$COVER_RATE")" || die "invalid COVER_RATE: $COVER_RATE; expected <positive_integer>[K|M|G]"
  uint_le "$bps" "$RELAY_ENV_UINT64_MAX" || die "COVER_RATE exceeds supported 64-bit positive integer range: $COVER_RATE"
  # shellcheck disable=SC2034
  RELAY_COVER_RATE_BPS="$bps"
  # shellcheck disable=SC2034
  RELAY_BUSY_THRESHOLD_BPS="$bps"
  RELAY_BUSY_RATE_BPS="$(uint_div_ceil_small "$bps" "$RELAY_BUSY_RATE_DIVISOR")" || die "failed to derive busy rate from COVER_RATE"
  uint_ge "$RELAY_BUSY_RATE_BPS" "1" || die "derived busy rate is invalid"
  uint_le "$RELAY_BUSY_RATE_BPS" "$bps" || die "derived busy rate exceeds COVER_RATE"
}

validate_relay_cover_duration_range() {
  local min_seconds=""
  local max_seconds=""
  local minimum_allowed

  [[ -n "${COVER_DURATION_RANGE:-}" ]] || die "COVER_DURATION_RANGE must not be empty"
  [[ "$COVER_DURATION_RANGE" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]] || \
    die "invalid COVER_DURATION_RANGE: $COVER_DURATION_RANGE; expected <min_seconds>-<max_seconds>"

  min_seconds="${BASH_REMATCH[1]}"
  max_seconds="${BASH_REMATCH[2]}"
  minimum_allowed="$((RELAY_VALIDATED_TARGET_COUNT * 15))"

  ((10#$min_seconds <= 10#$max_seconds)) || die "COVER_DURATION_RANGE min must be <= max"
  ((10#$max_seconds <= 3570)) || die "COVER_DURATION_RANGE max must be <= 3570"
  ((10#$min_seconds >= minimum_allowed)) || \
    die "COVER_DURATION_RANGE min must be at least ${minimum_allowed} seconds for ${RELAY_VALIDATED_TARGET_COUNT} targets"

  # shellcheck disable=SC2034
  RELAY_DURATION_MIN_SECONDS="$min_seconds"
  # shellcheck disable=SC2034
  RELAY_DURATION_MAX_SECONDS="$max_seconds"
}

validate_relay_cover_type() {
  [[ -n "${COVER_TYPE:-}" ]] || die "COVER_TYPE must not be empty"

  case "$COVER_TYPE" in
    auto|udp|tcp)
      ;;
    *)
      die "COVER_TYPE must be one of: auto, udp, tcp"
      ;;
  esac
}

validate_loaded_relay_env() {
  local require_existing_interface="${1:-1}"

  require_env "${RELAY_ENV_ALLOWED_FIELDS[@]}"
  validate_relay_egress_dev "$require_existing_interface"
  validate_relay_cover_targets
  validate_relay_cover_rate
  validate_relay_cover_duration_range
  validate_relay_cover_type
}

load_and_validate_relay_env() {
  local env_file="${1:?relay env path is required}"
  local require_existing_interface="${2:-1}"

  load_relay_env_file "$env_file"
  validate_loaded_relay_env "$require_existing_interface"
}

iperf3_supports_option() {
  local option="${1:?option is required}"

  iperf3 --help 2>&1 | grep -Fq -- "$option"
}

require_relay_iperf3_capabilities() {
  require_cmd iperf3 grep

  iperf3_supports_option "--bind-dev" || die "iperf3 does not support required option: --bind-dev"
  iperf3_supports_option "--dscp" || die "iperf3 does not support required option: --dscp"
  iperf3_supports_option "--fq-rate" || die "iperf3 does not support required option: --fq-rate"
}

legacy_relay_resources_present() {
  local path
  local -a paths=(
    /etc/systemd/system/relay-cover-qos.service
    /usr/local/sbin/relay-cover-setup-qos.sh
    /usr/local/sbin/relay-cover-remove-qos.sh
  )

  if systemctl cat relay-cover-qos.service >/dev/null 2>&1; then
    return 0
  fi

  for path in "${paths[@]}"; do
    if [[ -e "$path" ]]; then
      return 0
    fi
  done

  return 1
}

require_no_legacy_relay_resources() {
  legacy_relay_resources_present || return 0
  die "legacy relay QoS resources are still present; run the old relay/uninstall.sh first, then retry with the new 5-field config"
}

systemctl_unit_exists() {
  local unit="${1:?unit is required}"
  systemctl cat "$unit" >/dev/null 2>&1
}

systemctl_is_enabled() {
  local unit="${1:?unit is required}"
  local state

  state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  [[ "$state" == "enabled" ]]
}

systemctl_is_activeish() {
  local unit="${1:?unit is required}"
  local state

  state="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
  [[ "$state" == "active" || "$state" == "activating" ]]
}

iptables_cmd_mode() {
  local cmd="${1:?iptables command is required}"
  local version

  command -v "$cmd" >/dev/null 2>&1 || return 1
  version="$("$cmd" --version 2>/dev/null || true)"

  case "$version" in
    *"(legacy)"*) printf '%s\n' "legacy" ;;
    *"(nf_tables)"*) printf '%s\n' "nf_tables" ;;
    *) printf '%s\n' "unknown" ;;
  esac
}

iptables_mode() {
  iptables_cmd_mode iptables
}

ip6tables_mode() {
  iptables_cmd_mode ip6tables
}

require_iptables_legacy() {
  local mode

  require_cmd iptables
  mode="$(iptables_mode)" || die "iptables command not found"
  [[ "$mode" == "legacy" ]] || die "iptables must be in legacy mode, but 'iptables --version' reports mode: $mode"
}

require_ip6tables_legacy() {
  local mode

  require_cmd ip6tables
  mode="$(ip6tables_mode)" || die "ip6tables command not found"
  [[ "$mode" == "legacy" ]] || die "ip6tables must be in legacy mode, but 'ip6tables --version' reports mode: $mode"
}
