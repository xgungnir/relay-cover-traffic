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
REALM_BIN="/usr/local/bin/realm"
REALM_DIR="/etc/realm"
REALM_CONFIG="$REALM_DIR/config.toml"
UNIT_FILE="/etc/systemd/system/realm.service"
REALM_TMP_DIR=""
TARGET_REALM_VERSION=""

cleanup_realm_tmp() {
  if [[ -n "${REALM_TMP_DIR:-}" ]]; then
    rm -rf "$REALM_TMP_DIR"
  fi
}

trap cleanup_realm_tmp EXIT

install_realm_from_tarball() {
  local extract_dir=""
  local archive=""
  local realm_src=""
  local install_tmp=""

  REALM_TMP_DIR="$(mktemp -d)"
  extract_dir="$REALM_TMP_DIR/extract"
  archive="$REALM_TMP_DIR/realm.tar.gz"
  mkdir -p "$extract_dir"

  log "INFO" "downloading realm ${TARGET_REALM_VERSION} from $REALM_TARBALL_URL"
  curl -fL "$REALM_TARBALL_URL" -o "$archive"

  log "INFO" "extracting realm tarball"
  tar -xzf "$archive" -C "$extract_dir"

  realm_src="$(find "$extract_dir" -type f -name realm -print -quit)"
  [[ -n "$realm_src" ]] || die "realm binary not found inside downloaded tarball"

  log "INFO" "installing realm to $REALM_BIN"
  install_tmp="$(mktemp "${REALM_BIN}.tmp.XXXXXX")"
  install -m 0755 "$realm_src" "$install_tmp"
  mv -f "$install_tmp" "$REALM_BIN"

  cleanup_realm_tmp
  REALM_TMP_DIR=""
}

realm_target_version_from_url() {
  local url="${1:?realm tarball url is required}"

  if [[ "$url" =~ /download/v?([0-9]+([.][0-9]+)+)/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$url" =~ (^|[^0-9])v([0-9]+([.][0-9]+)+)([^0-9]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

realm_installed_version() {
  local output=""

  output="$("$REALM_BIN" -v 2>&1 || "$REALM_BIN" --version 2>&1 || true)"
  if [[ "$output" =~ Realm[[:space:]]+v?([0-9]+([.][0-9]+)+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$output" =~ (^|[^0-9])v?([0-9]+([.][0-9]+)+)([^0-9]|$) ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi

  return 1
}

ensure_realm_binary_version() {
  local current_version=""
  local installed_version=""

  if [[ -e "$REALM_BIN" && ! -f "$REALM_BIN" ]]; then
    die "$REALM_BIN exists but is not a regular file"
  fi

  if [[ -f "$REALM_BIN" ]]; then
    chmod 0755 "$REALM_BIN"
    current_version="$(realm_installed_version || true)"
    if [[ -z "$current_version" ]]; then
      log "WARN" "could not detect current realm version at $REALM_BIN; replacing with target version ${TARGET_REALM_VERSION}"
      install_realm_from_tarball
    elif [[ "$current_version" == "$TARGET_REALM_VERSION" ]]; then
      log "INFO" "realm binary already at target version ${TARGET_REALM_VERSION}: $REALM_BIN"
    else
      log "INFO" "realm version mismatch: current=${current_version} target=${TARGET_REALM_VERSION}; replacing $REALM_BIN"
      install_realm_from_tarball
    fi
  else
    log "INFO" "realm binary missing at $REALM_BIN; installing target version ${TARGET_REALM_VERSION}"
    install_realm_from_tarball
  fi

  [[ -x "$REALM_BIN" ]] || die "realm binary is not executable at $REALM_BIN"

  installed_version="$(realm_installed_version || true)"
  if [[ -z "$installed_version" ]]; then
    log "WARN" "could not verify installed realm version with '$REALM_BIN -v'"
  elif [[ "$installed_version" != "$TARGET_REALM_VERSION" ]]; then
    die "installed realm version is ${installed_version}, expected ${TARGET_REALM_VERSION}"
  else
    log "INFO" "realm version verified: ${installed_version}"
  fi
}

require_root
require_cmd systemctl install curl tar find mktemp mkdir chmod grep mv
sync_runtime_env_file "$ENV_SOURCE" "$ENV_FILE"
load_env_file "$ENV_FILE"
require_env REALM_TARBALL_URL

case "$REALM_TARBALL_URL" in
  http://*|https://*)
    ;;
  *)
    die "REALM_TARBALL_URL must be an http or https URL"
    ;;
esac

TARGET_REALM_VERSION="$(realm_target_version_from_url "$REALM_TARBALL_URL")" || \
  die "could not parse realm version from REALM_TARBALL_URL; expected a URL containing /download/vX.Y.Z/"
log "INFO" "target realm version from REALM_TARBALL_URL: $TARGET_REALM_VERSION"
ensure_realm_binary_version

install -d -m 0755 "$REALM_DIR"
if [[ -e "$REALM_CONFIG" ]]; then
  log "INFO" "preserving existing realm config: $REALM_CONFIG"
else
  log "INFO" "creating empty realm config: $REALM_CONFIG"
  : >"$REALM_CONFIG"
  chmod 0644 "$REALM_CONFIG"
fi

log "INFO" "writing systemd unit to $UNIT_FILE"
cat >"$UNIT_FILE" <<'UNIT'
[Unit]
Description=Realm Relay Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT_FILE"

systemctl daemon-reload
systemctl enable realm.service

if grep -q '[^[:space:]]' "$REALM_CONFIG"; then
  log "INFO" "$REALM_CONFIG is not empty; starting realm.service"
  systemctl restart realm.service
else
  systemctl stop realm.service 2>/dev/null || true
  log "WARN" "$REALM_CONFIG is empty; realm.service is enabled but not started"
  log "WARN" "edit $REALM_CONFIG, then run: systemctl restart realm.service"
fi

log "INFO" "realm.service setup complete"
