#!/usr/bin/env bash
set -Eeuo pipefail

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
    [[ -n "${!name:-}" ]] || die "required env var is unset or empty: $name"
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
  install -D -m "$mode" "$src" "$dest"
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
  local count=0

  while IFS= read -r item; do
    item="$(trim "$item")"
    [[ -z "$item" ]] && continue

    parse_host_port "$item"
    printf '%s\t%s\n' "$TARGET_HOST" "$TARGET_PORT"
    count=$((count + 1))
  done < <(printf '%s\n' "$raw" | tr ',' '\n')

  [[ "$count" -gt 0 ]] || die "target list is empty"
}

rate_to_bps() {
  local raw="${1:?rate is required}"
  local cleaned="${raw//[[:space:]]/}"
  local lower="${cleaned,,}"
  local number=""
  local prefix=""
  local multiplier=1

  if [[ "$lower" =~ ^([0-9]+)([kmgt]?)(bit|bits|bps|b)?$ ]]; then
    number="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  case "$prefix" in
    "") multiplier=1 ;;
    k) multiplier=1000 ;;
    m) multiplier=1000000 ;;
    g) multiplier=1000000000 ;;
    t) multiplier=1000000000000 ;;
    *) return 1 ;;
  esac

  printf '%s\n' "$((10#$number * multiplier))"
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
