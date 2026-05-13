#!/usr/bin/env bash
# eip-hermes-component:
#   name: example
#   description: One-line summary of what this component installs or configures
#   default: enabled
#   ports:
#   requires:
#
# Component contract:
#   1. The header block above is parsed by install.sh. Keep the schema:
#      `# <key>: <value>` lines indented with two spaces, in this order.
#      - name:        unique slug (matches filename suffix). No spaces.
#      - description: single line. Shown by `install.sh --list`.
#      - default:     `enabled` or `disabled`. Disabled components only run
#                     when the user passes `--only <name>` or `--with <name>`.
#      - ports:       comma-separated list `PORT:LABEL`, e.g. `50090:minio`.
#                     Empty if the component opens no listening ports.
#      - requires:    comma-separated list of other component `name:`s. The
#                     orchestrator auto-pulls these (logging which it added).
#
#   2. The script must be both sourceable and runnable standalone. Use the
#      bootstrap block below verbatim.
#
#   3. Define `run()`. Optionally define `verify()` for post-install health
#      checks. The orchestrator calls them in that order, per component.

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

# === implementation =========================================================

example_install() {
  log "Replace this with your install body"
}

# === component entry points ================================================

run() {
  example_install
}

verify() {
  : # Optional. Replace with health checks (curl, command -v, etc.).
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  if declare -f verify >/dev/null; then verify; fi
fi
