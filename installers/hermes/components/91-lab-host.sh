#!/usr/bin/env bash
# eip-hermes-component:
#   name: lab-host
#   description: Clones eip-public/win11-forge into ~/win11-forge. Lab-host pre-reqs (KVM/libvirt/qemu/ovmf, ghidriff, BinExport, Win11/virtio ISOs) are NOT installed here -- run ~/win11-forge/install-deps.sh yourself when you want to build a lab.
#   default: enabled
#   ports:
#   requires:

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="$HOME"

WINFORGE_REPO_URL="${WINFORGE_REPO_URL:-https://github.com/eip-public/win11-forge}"
WINFORGE_BRANCH="${WINFORGE_BRANCH:-main}"
WINFORGE_DIR="${WINFORGE_DIR:-$TARGET_HOME/win11-forge}"

clone_or_update_winforge() {
    if [ -d "$WINFORGE_DIR/.git" ]; then
        require_clean_checkout "$WINFORGE_DIR"
        log "Updating win11-forge at $WINFORGE_DIR"
        git -C "$WINFORGE_DIR" fetch origin "$WINFORGE_BRANCH" \
            || warn "Could not fetch win11-forge branch"
        git -C "$WINFORGE_DIR" checkout "$WINFORGE_BRANCH" \
            || warn "Could not checkout win11-forge branch"
        git -C "$WINFORGE_DIR" pull --ff-only origin "$WINFORGE_BRANCH" \
            || warn "Could not fast-forward win11-forge; leaving existing checkout as-is"
    else
        log "Cloning $WINFORGE_REPO_URL into $WINFORGE_DIR"
        mkdir -p "$(dirname "$WINFORGE_DIR")"
        git clone --branch "$WINFORGE_BRANCH" "$WINFORGE_REPO_URL" "$WINFORGE_DIR" \
            || fail "git clone of $WINFORGE_REPO_URL failed; set WINFORGE_REPO_URL/WINFORGE_BRANCH and re-run"
    fi
    success "win11-forge ready at $WINFORGE_DIR"
}

run() {
    clone_or_update_winforge
}

verify() {
    if [ -d "$WINFORGE_DIR/.git" ]; then
        success "win11-forge clone present at $WINFORGE_DIR"
    else
        warn "win11-forge clone missing at $WINFORGE_DIR"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    run
    if declare -f verify >/dev/null; then verify; fi
fi
