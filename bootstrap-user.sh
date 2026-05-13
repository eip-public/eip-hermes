#!/usr/bin/env bash
# bootstrap-user.sh -- grant the current user passwordless sudo for eip-hermes.
#
# Run this once with sudo as the user that will run the main installer.
# It does the bare minimum to get that user ready to drive
# installers/hermes/install.sh:
#
#   1. Adds the invoking user to the `sudo` group (if not already in it).
#   2. Writes /etc/sudoers.d/eip-hermes-<user> granting passwordless sudo,
#      validated with `visudo -cf` before installing.
#   3. Verifies the policy actually took effect.
#
# Why a separate script: passwordless sudo is security-sensitive. Keeping it
# out of the rerunnable per-component installer means anyone reviewing the
# repo can audit exactly what gets granted, in one short file. The main
# installer is rerunnable and additive; this script runs once.
#
# Usage:
#   sudo ./bootstrap-user.sh
#
# Targets $SUDO_USER. Refuses to run as actual root (no $SUDO_USER) -- the
# point of the grant is to let a non-root user drive the installer without
# password prompts.
#
# Options:
#   -h | --help

set -Eeuo pipefail

log()     { printf '[ * ] %s\n' "$*"; }
success() { printf '[ OK ] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*" >&2; }
fail()    { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "Unknown option: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || fail "Must be run with sudo (try: sudo $0)"

if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = "root" ]; then
  fail "No invoking user -- run with sudo from your normal login, not as root."
fi

TARGET_USER="$SUDO_USER"

case "$TARGET_USER" in
  *[!a-z0-9_-]*|nobody) fail "Invalid username: '$TARGET_USER'" ;;
esac

log "Target user: $TARGET_USER"

# ---------------------------------------------------------------------------
# 1. Add to sudo group
# ---------------------------------------------------------------------------
if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx sudo; then
  success "$TARGET_USER already in sudo group"
else
  log "Adding $TARGET_USER to sudo group"
  usermod -aG sudo "$TARGET_USER"
  success "$TARGET_USER added to sudo group"
fi

# ---------------------------------------------------------------------------
# 2. Grant passwordless sudo (validated)
# ---------------------------------------------------------------------------
SUDOERS_FILE="/etc/sudoers.d/eip-hermes-$TARGET_USER"
SUDOERS_CONTENT="$TARGET_USER ALL=(ALL) NOPASSWD:ALL"

if [ -f "$SUDOERS_FILE" ] && grep -qxF "$SUDOERS_CONTENT" "$SUDOERS_FILE"; then
  success "Passwordless sudo already configured for $TARGET_USER ($SUDOERS_FILE)"
else
  log "Writing $SUDOERS_FILE"
  tmp="$(mktemp)"
  printf '%s\n' "$SUDOERS_CONTENT" >"$tmp"
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    fail "visudo validation rejected the generated sudoers fragment"
  fi
  install -m 0440 -o root -g root "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"
  success "Passwordless sudo granted to $TARGET_USER ($SUDOERS_FILE, 0440 root:root)"
fi

# ---------------------------------------------------------------------------
# 3. Verify the policy took effect
# ---------------------------------------------------------------------------
if runuser -u "$TARGET_USER" -- sudo -n true >/dev/null 2>&1; then
  success "Verified: $TARGET_USER can sudo without a password"
else
  warn "Could not verify passwordless sudo for $TARGET_USER (may need fresh login)"
fi

# ---------------------------------------------------------------------------
# Next step
# ---------------------------------------------------------------------------
cat <<EOF

Next step:
  Run the main installer (no sudo needed; it elevates per-component):

    ./installers/hermes/install.sh

The main installer should never need to be run as root. If it asks you to,
something has changed and bootstrap-user.sh should be updated.
EOF
