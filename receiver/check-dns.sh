#!/usr/bin/env bash
set -Eeuo pipefail

DNS_CHECK_DOMAIN="${DNS_CHECK_DOMAIN:-cp.cloudflare.com}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 8.8.4.4}"
RESOLV_CONF="/etc/resolv.conf"

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

package_installed() {
  local package="${1:?package name is required}"

  command -v dpkg-query >/dev/null 2>&1 || return 1
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'
}

unit_available() {
  local unit="${1:?unit name is required}"

  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl cat "$unit" >/dev/null 2>&1
}

resolv_conf_has_nameserver() {
  [[ -s "$RESOLV_CONF" ]] && grep -Eq '^[[:space:]]*nameserver[[:space:]]+' "$RESOLV_CONF"
}

dns_lookup_ok() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 6 getent ahosts "$DNS_CHECK_DOMAIN" >/dev/null 2>&1
  else
    getent ahosts "$DNS_CHECK_DOMAIN" >/dev/null 2>&1
  fi
}

dns_ok() {
  resolv_conf_has_nameserver && dns_lookup_ok
}

backup_resolv_conf() {
  local backup

  [[ -e "$RESOLV_CONF" || -L "$RESOLV_CONF" ]] || return 0
  backup="${RESOLV_CONF}.relay-cover-backup.$(date +%Y%m%d%H%M%S)"
  cp -a "$RESOLV_CONF" "$backup" 2>/dev/null || true
  log "INFO" "backed up current $RESOLV_CONF to $backup"
}

write_static_resolv_conf() {
  local server

  log "WARN" "writing static $RESOLV_CONF using DNS_SERVERS='$DNS_SERVERS'"
  backup_resolv_conf
  rm -f "$RESOLV_CONF"
  {
    for server in $DNS_SERVERS; do
      printf 'nameserver %s\n' "$server"
    done
    printf '%s\n' 'options timeout:2 attempts:3 rotate'
  } >"$RESOLV_CONF"
  chmod 0644 "$RESOLV_CONF"
}

fix_with_systemd_resolved() {
  local target=""

  package_installed systemd-resolved || return 1
  unit_available systemd-resolved.service || return 1

  log "INFO" "detected systemd-resolved; enabling and starting it"
  systemctl enable --now systemd-resolved.service || return 1

  if [[ -s /run/systemd/resolve/resolv.conf ]]; then
    target="/run/systemd/resolve/resolv.conf"
  elif [[ -s /run/systemd/resolve/stub-resolv.conf ]]; then
    target="/run/systemd/resolve/stub-resolv.conf"
  else
    log "WARN" "systemd-resolved is present, but no resolved resolv.conf target exists"
    return 1
  fi

  if [[ ! -L "$RESOLV_CONF" || "$(readlink "$RESOLV_CONF" 2>/dev/null || true)" != "$target" ]]; then
    log "INFO" "pointing $RESOLV_CONF to $target"
    backup_resolv_conf
    ln -sfn "$target" "$RESOLV_CONF"
  fi

  dns_ok
}

fix_with_resolvconf() {
  package_installed openresolv || package_installed resolvconf || command -v resolvconf >/dev/null 2>&1 || return 1
  command -v resolvconf >/dev/null 2>&1 || return 1

  log "INFO" "detected resolvconf/openresolv; refreshing resolvconf state"
  resolvconf -u 2>/dev/null || true

  if [[ -s /run/resolvconf/resolv.conf ]] && grep -Eq '^[[:space:]]*nameserver[[:space:]]+' /run/resolvconf/resolv.conf; then
    if [[ ! -L "$RESOLV_CONF" || "$(readlink "$RESOLV_CONF" 2>/dev/null || true)" != "/run/resolvconf/resolv.conf" ]]; then
      log "INFO" "pointing $RESOLV_CONF to /run/resolvconf/resolv.conf"
      backup_resolv_conf
      ln -sfn /run/resolvconf/resolv.conf "$RESOLV_CONF"
    fi
  fi

  dns_ok
}

require_root
command -v getent >/dev/null 2>&1 || die "required command not found: getent"
command -v grep >/dev/null 2>&1 || die "required command not found: grep"

log "INFO" "checking DNS with domain: $DNS_CHECK_DOMAIN"
log "INFO" "packages: systemd-resolved=$(package_installed systemd-resolved && printf installed || printf missing), openresolv=$(package_installed openresolv && printf installed || printf missing), resolvconf=$(package_installed resolvconf && printf installed || printf missing)"

if [[ -L "$RESOLV_CONF" ]]; then
  log "INFO" "$RESOLV_CONF is a symlink to $(readlink "$RESOLV_CONF")"
elif [[ -e "$RESOLV_CONF" ]]; then
  log "INFO" "$RESOLV_CONF is a regular file"
else
  log "WARN" "$RESOLV_CONF is missing"
fi

if dns_ok; then
  log "INFO" "DNS is working; no changes needed"
  exit 0
fi

log "WARN" "DNS is not working; attempting repair"

if fix_with_systemd_resolved; then
  log "INFO" "DNS fixed with systemd-resolved"
elif fix_with_resolvconf; then
  log "INFO" "DNS fixed with resolvconf/openresolv"
else
  write_static_resolv_conf
  dns_ok || die "DNS still does not resolve $DNS_CHECK_DOMAIN after writing $RESOLV_CONF"
  log "INFO" "DNS fixed with static $RESOLV_CONF"
fi

getent ahosts "$DNS_CHECK_DOMAIN" | sed -n '1,4p'
