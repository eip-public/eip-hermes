#!/usr/bin/env bash
# Shared helpers for installers/hermes components.
#
# Source this file from the orchestrator or from a component bootstrapping
# itself for standalone execution.

# ------------------------------ Logging ------------------------------------
# Bracketed level prefix, no color, no icons. Same shape in tty, in
# `tee install.log`, in journalctl, in CI viewers.
log()     { printf '[ * ] %s\n' "$*"; }
success() { printf '[ OK ] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*" >&2; }
fail()    { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
die()     { fail "$@"; }

# ------------------------------- Helpers ------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_setup_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then printf '%s' "$SUDO_USER"; else id -un; fi
}

detect_setup_home() {
  local u="$1"
  if [ "$u" = "$(id -un)" ]; then printf '%s' "$HOME"; else getent passwd "$u" | cut -d: -f6; fi
}

sudo_cmd() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

rand_hex() { openssl rand -hex "$1"; }
rand_b64() { openssl rand -base64 "$1" | tr -d '\n'; }

# Ensure user-local install prefixes are on PATH. Without this, a component
# run standalone (e.g. ./components/30-control-plane.sh) would not see hermes
# at /root/.local/bin/hermes, and the upstream install_hermes_control_plane_services
# would bake the bare command `hermes` into the dashboard systemd unit -- which
# systemd cannot resolve because it ignores Environment=PATH for ExecStart
# (status 203/EXEC). The orchestrator already extends PATH via install_or_update_hermes;
# this block makes standalone runs match.
prepend_path() {
  local p="$1"
  case ":$PATH:" in
    *":$p:"*) ;;
    *) export PATH="$p:$PATH" ;;
  esac
}
prepend_path "/usr/local/bin"
prepend_path "$HOME/.local/bin"

# Refuse to update a git checkout that has local modifications. Used by the
# clone_or_update_* paths in 20-hermes, 40-honcho, 25-cve-skills, and
# 91-lab-host so a re-run of install.sh can't silently fail to fast-forward
# (and then proceed against a stale tree) when the user is mid-edit.
require_clean_checkout() {
  local dir="${1:?dir required}"
  [ -d "$dir/.git" ] || return 0   # nothing to check on a fresh install
  if ! git -C "$dir" diff --quiet 2>/dev/null \
     || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    fail "Local modifications in $dir -- commit or stash, then re-run."
  fi
}
