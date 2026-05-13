#!/usr/bin/env bash
# eip-hermes-component:
#   name: recon
#   description: Recon scanners -- ffuf, nuclei, masscan
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

install_ffuf() {
  if have_cmd ffuf && ffuf -V 2>&1 | grep -q "$FFUF_VERSION"; then
    log "ffuf ${FFUF_VERSION} already installed"
    return 0
  fi

  log "Installing ffuf ${FFUF_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  download_to \
    "$tmp/ffuf.tgz" \
    "https://github.com/ffuf/ffuf/releases/download/v${FFUF_VERSION}/ffuf_${FFUF_VERSION}_linux_${GOARCH}.tar.gz"
  tar xzf "$tmp/ffuf.tgz" -C "$tmp"
  install -m 0755 "$tmp/ffuf" "$BIN/ffuf"
  rm -rf "$tmp"
}

install_nuclei() {
  if have_cmd nuclei && nuclei -version 2>&1 | grep -q "$NUCLEI_VERSION"; then
    log "nuclei ${NUCLEI_VERSION} already installed"
    return 0
  fi

  log "Installing nuclei ${NUCLEI_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  download_to \
    "$tmp/nuclei.zip" \
    "https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/nuclei_${NUCLEI_VERSION}_linux_${GOARCH}.zip"
  unzip -q "$tmp/nuclei.zip" -d "$tmp"
  install -m 0755 "$tmp/nuclei" "$BIN/nuclei"
  rm -rf "$tmp"
}

install_masscan() {
  local dir=/opt/masscan
  if have_cmd masscan; then
    log "masscan already installed"
    return 0
  fi

  log "Installing masscan from source"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    retry 3 10 git clone --depth 1 https://github.com/robertdavidgraham/masscan "$dir"
  fi
  make -C "$dir"
  make -C "$dir" install
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 60-recon.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/60-recon.sh"
    return $?
  fi
  detect_arch
  setup_context

  install_ffuf
  install_nuclei
  install_masscan
}

verify() {
  for cmd in ffuf nuclei masscan; do
    if need_cmd "$cmd"; then success "$cmd: $(command -v "$cmd")"; else warn "$cmd not on PATH"; fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
