#!/usr/bin/env bash
# eip-hermes-component:
#   name: hermes
#   description: Native Hermes Agent install/update from upstream
#   default: enabled
#   ports:
#   requires: runtimes

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

install_or_update_hermes() {
  if [ "$INSTALL_HERMES" != true ]; then warn "Skipping Hermes install/update"; return 0; fi
  mkdir -p "$HERMES_HOME"
  if [ -d "$HERMES_INSTALL_DIR/.git" ]; then
    log "Updating Hermes checkout at $HERMES_INSTALL_DIR"
    git -C "$HERMES_INSTALL_DIR" fetch origin "$HERMES_BRANCH" || warn "Could not fetch Hermes branch"
    git -C "$HERMES_INSTALL_DIR" checkout "$HERMES_BRANCH" || warn "Could not checkout Hermes branch"
    git -C "$HERMES_INSTALL_DIR" pull --ff-only origin "$HERMES_BRANCH" || warn "Could not fast-forward Hermes checkout; leaving existing checkout as-is"
  else
    log "Cloning Hermes Agent into $HERMES_INSTALL_DIR"
    mkdir -p "$(dirname "$HERMES_INSTALL_DIR")"
    git clone --branch "$HERMES_BRANCH" "$HERMES_REPO_URL" "$HERMES_INSTALL_DIR"
  fi
  log "Running Hermes installer in skip-setup mode"
  if ! bash "$HERMES_INSTALL_DIR/scripts/install.sh" --dir "$HERMES_INSTALL_DIR" --hermes-home "$HERMES_HOME" --branch "$HERMES_BRANCH" --skip-setup; then
    if command -v hermes >/dev/null 2>&1; then
      warn "Hermes installer reported an error, but an existing hermes command is available; continuing."
    else
      fail "Hermes installer failed and no existing hermes command was found."
    fi
  fi
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  need_cmd hermes && success "Hermes installed: $(command -v hermes)" || warn "hermes command is not on PATH yet."
}

# === component entry points ================================================

run() {
  # Refuse to overwrite a Hermes checkout the user has local edits in.
  # The extracted install_or_update_hermes does `git pull --ff-only` and
  # masks failures with `|| warn`, which would otherwise install against a
  # stale tree without a clear signal.
  require_clean_checkout "$HERMES_INSTALL_DIR"
  install_or_update_hermes
}

verify() {
  if need_cmd hermes; then success "hermes on PATH: $(command -v hermes)"; else warn "hermes not on PATH"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
