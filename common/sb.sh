#!/usr/bin/env bash
set -Eeuo pipefail

if ! declare -F log >/dev/null 2>&1 || ! declare -F die >/dev/null 2>&1; then
  COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=common/lib.sh
  source "$COMMON_DIR/lib.sh"
fi

SAGERNET_KEYRING="${SAGERNET_KEYRING:-/etc/apt/keyrings/sagernet.asc}"
SAGERNET_SOURCE_FILE="${SAGERNET_SOURCE_FILE:-/etc/apt/sources.list.d/sagernet.sources}"
SING_BOX_CONFIG="${SING_BOX_CONFIG:-/etc/sing-box/config.json}"

is_debian_or_ubuntu() {
  local os_id=""
  local os_like=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    os_id="${ID:-}"
    os_like="${ID_LIKE:-}"
  fi

  [[ "$os_id" == "debian" || "$os_id" == "ubuntu" || "$os_like" == *"debian"* || "$os_like" == *"ubuntu"* ]]
}

sagernet_repo_present() {
  grep -RqsE '(^|[[:space:]])https://deb\.sagernet\.org/?([[:space:]]|$)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null
}

sagernet_key_present() {
  [[ -s "$SAGERNET_KEYRING" ]]
}

install_sagernet_key() {
  require_cmd curl chmod mkdir

  mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
  curl -fsSL https://sing-box.app/gpg.key -o "$SAGERNET_KEYRING"
  chmod a+r "$SAGERNET_KEYRING"
}

write_sagernet_source() {
  require_cmd chmod mkdir

  mkdir -p /etc/apt/sources.list.d
  tee "$SAGERNET_SOURCE_FILE" >/dev/null <<SOURCE
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: $SAGERNET_KEYRING
SOURCE
  chmod 0644 "$SAGERNET_SOURCE_FILE"
}

sing_box_installed() {
  dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -q 'install ok installed'
}

install_sing_box_from_sagernet_repo() {
  local repo_changed=0
  local was_installed=0

  is_debian_or_ubuntu || die "sing-box repository installation currently supports Debian/Ubuntu APT systems only"
  require_cmd apt-get curl chmod grep mkdir dpkg-query tee

  if sagernet_key_present; then
    log "INFO" "Sagernet APT keyring already present"
  else
    log "INFO" "installing Sagernet APT keyring"
    install_sagernet_key
    repo_changed=1
  fi

  if sagernet_repo_present; then
    log "INFO" "Sagernet APT repository already configured"
  else
    log "INFO" "adding Sagernet APT repository for sing-box"
    write_sagernet_source
    repo_changed=1
  fi

  if sing_box_installed; then
    was_installed=1
    log "INFO" "sing-box already installed: $(sing-box version 2>/dev/null | head -n 1 || printf 'version unknown')"
  fi

  if [[ "$repo_changed" -eq 1 || "$was_installed" -eq 0 ]]; then
    apt-get update
  fi

  if [[ "$was_installed" -eq 0 ]]; then
    log "INFO" "installing sing-box from Sagernet APT repository"
    apt-get install -y sing-box
    log "WARN" "sing-box was installed for the first time by this script."
    log "WARN" "Adjust your sing-box configuration at $SING_BOX_CONFIG before starting or restarting sing-box."
  fi
}

enable_sing_box_service() {
  require_cmd systemctl

  log "INFO" "enabling sing-box.service"
  systemctl enable sing-box.service
}

sing_box_config_ready() {
  local config_file="${1:-$SING_BOX_CONFIG}"

  [[ -s "$config_file" ]]
}
