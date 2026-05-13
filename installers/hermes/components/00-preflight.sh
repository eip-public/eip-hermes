#!/usr/bin/env bash
# eip-hermes-component:
#   name: preflight
#   description: Verify the host is Ubuntu 24.04 (or noble derivative)
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

require_ubuntu_2404() {
  [ -r /etc/os-release ] || fail "Cannot detect OS. This script is for Ubuntu 24.04."
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ]; then
    success "Detected ${PRETTY_NAME}"
    return 0
  fi
  if [ "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" = "noble" ]; then
    warn "Detected Ubuntu 24.04/noble derivative: ${PRETTY_NAME:-unknown}. Proceeding."
    return 0
  fi
  fail "This script targets Ubuntu 24.04/noble. Detected: ${PRETTY_NAME:-unknown}."
}

# === new check: passwordless sudo for the running user ====================
# The installer is designed to run as a non-root user with passwordless sudo.
# Running as root works (sudo_cmd is a no-op then) but is discouraged because
# config and state end up under /root/* instead of the intended user home.
require_passwordless_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    warn "Running as root. The installer works, but the recommended pattern is a non-root user with passwordless sudo. See bootstrap-user.sh."
    return 0
  fi
  if sudo -n true >/dev/null 2>&1; then
    success "Passwordless sudo OK for $(id -un)"
    return 0
  fi
  fail "User $(id -un) cannot sudo without a password. Run \`sudo $INSTALLER_DIR/../../bootstrap-user.sh\` once, then re-run this installer."
}

# === component entry points ================================================

run() {
  require_ubuntu_2404
  require_passwordless_sudo
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
fi
