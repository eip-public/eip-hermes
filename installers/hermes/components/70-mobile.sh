#!/usr/bin/env bash
# eip-hermes-component:
#   name: mobile
#   description: Android tooling -- apktool, jadx, apkeep
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

install_apktool() {
  local dir=/opt/apktool
  local jar="$dir/apktool_${APKTOOL_VERSION}.jar"
  if [[ ! -s "$jar" ]]; then
    log "Installing apktool ${APKTOOL_VERSION}"
    mkdir -p "$dir"
    download_to \
      "$jar" \
      "https://github.com/iBotPeaches/Apktool/releases/download/v${APKTOOL_VERSION}/apktool_${APKTOOL_VERSION}.jar"
    ln -sf "$jar" "$dir/apktool.jar"
  else
    log "apktool ${APKTOOL_VERSION} already installed"
  fi
  cat > "$BIN/apktool" <<EOF
#!/usr/bin/env bash
exec java -jar "$dir/apktool.jar" "\$@"
EOF
  chmod 0755 "$BIN/apktool"
}

install_jadx() {
  if [[ -x /opt/jadx/bin/jadx ]] && /opt/jadx/bin/jadx --version 2>&1 | grep -q "$JADX_VERSION"; then
    log "jadx ${JADX_VERSION} already installed"
    return 0
  fi

  log "Installing jadx ${JADX_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  rm -rf /opt/jadx
  mkdir -p /opt/jadx
  download_to \
    "$tmp/jadx.zip" \
    "https://github.com/skylot/jadx/releases/download/v${JADX_VERSION}/jadx-${JADX_VERSION}.zip"
  unzip -q "$tmp/jadx.zip" -d /opt/jadx
  chmod 0755 /opt/jadx/bin/jadx /opt/jadx/bin/jadx-gui 2>/dev/null || true
  ln -sf /opt/jadx/bin/jadx "$BIN/jadx"
  ln -sf /opt/jadx/bin/jadx-gui "$BIN/jadx-gui"
  rm -rf "$tmp"
}

install_apkeep() {
  if have_cmd apkeep && apkeep --version 2>&1 | grep -q "$APKEEP_VERSION"; then
    log "apkeep ${APKEEP_VERSION} already installed"
    return 0
  fi

  log "Installing apkeep ${APKEEP_VERSION}"
  download_to \
    "$BIN/apkeep" \
    "https://github.com/EFForg/apkeep/releases/download/${APKEEP_VERSION}/apkeep-${APKEEP_ARCH}"
  chmod 0755 "$BIN/apkeep"
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 70-mobile.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/70-mobile.sh"
    return $?
  fi
  detect_arch
  setup_context

  install_apktool
  install_jadx
  install_apkeep
}

verify() {
  for cmd in apktool jadx apkeep; do
    if need_cmd "$cmd"; then success "$cmd: $(command -v "$cmd")"; else warn "$cmd not on PATH"; fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
