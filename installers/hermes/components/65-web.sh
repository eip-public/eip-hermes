#!/usr/bin/env bash
# eip-hermes-component:
#   name: web
#   description: Web/app-layer tools -- wp-cli, ysoserial, Burp Suite Community
#   default: enabled
#   ports:
#   requires: base-tools

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi
# shellcheck disable=SC1091
source "$INSTALLER_DIR/lib/security-tools.sh"

install_wp_cli() {
  if have_cmd wp; then
    log "wp-cli already installed"
    return 0
  fi
  log "Installing wp-cli"
  download_to "$BIN/wp" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod 0755 "$BIN/wp"
}

install_ysoserial() {
  local dir=/opt/ysoserial
  local jar="$dir/ysoserial-all.jar"
  if [[ ! -s "$jar" ]]; then
    log "Installing ysoserial ${YSOSERIAL_VERSION}"
    mkdir -p "$dir"
    download_to \
      "$jar" \
      "https://github.com/frohoff/ysoserial/releases/download/v${YSOSERIAL_VERSION}/ysoserial-all.jar"
  else
    log "ysoserial already installed"
  fi
  cat > "$BIN/ysoserial" <<EOF
#!/usr/bin/env bash
exec java -jar "$jar" "\$@"
EOF
  chmod 0755 "$BIN/ysoserial"
}

install_burp() {
  [[ "$INSTALL_BURP" == "1" ]] || return 0

  local dir=/opt/BurpSuiteCommunity
  if [[ -x "$dir/BurpSuiteCommunity" ]]; then
    log "Burp Suite already installed"
    ln -sf "$dir/BurpSuiteCommunity" "$BIN/burpsuite"
    return 0
  fi

  local installer="${BURP_INSTALLER:-}"
  if [[ -z "$installer" ]]; then
    installer="$CACHE_DIR/$BURP_INSTALLER_NAME"
  fi

  if [[ ! -s "$installer" ]]; then
    log "Downloading Burp Suite Community ${BURP_VERSION}"
    mkdir -p "$(dirname "$installer")"
    download_to \
      "$installer" \
      "https://portswigger.net/burp/releases/download?product=community&type=${BURP_DL_TYPE}&version=${BURP_VERSION}"
    chmod 0755 "$installer"
  fi

  log "Installing Burp Suite Community"
  chmod 0755 "$installer"
  "$installer" -q -dir "$dir" -Dinstall4j.suppressUnattendedReboot=true || \
    warn "Burp installer exited non-zero"
  [[ -x "$dir/BurpSuiteCommunity" ]] && ln -sf "$dir/BurpSuiteCommunity" "$BIN/burpsuite"
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 65-web.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/65-web.sh"
    return $?
  fi
  detect_arch
  setup_context

  install_wp_cli
  install_ysoserial
  install_burp
}

verify() {
  for cmd in wp ysoserial; do
    if need_cmd "$cmd"; then success "$cmd: $(command -v "$cmd")"; else warn "$cmd not on PATH"; fi
  done
  if [[ "$INSTALL_BURP" == "1" ]]; then
    if [ -x /opt/BurpSuiteCommunity/BurpSuiteCommunity ]; then
      success "burpsuite: /opt/BurpSuiteCommunity"
    else
      warn "burpsuite not installed at /opt/BurpSuiteCommunity"
    fi
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
