#!/usr/bin/env bash
# eip-hermes-component:
#   name: mcp-config
#   description: Register eip-mcp, semgrep, and ghidra-headless-mcp MCP servers in Hermes config
#   default: enabled
#   ports:
#   requires: hermes
#
# Hermes' interactive `hermes mcp add` writes entries under `mcp_servers:`
# in ~/.hermes/config.yaml. This component writes the same block directly
# so a fresh install doesn't require the user to walk the interactive
# flow per host. Idempotent: only adds entries that aren't already there;
# never touches a server entry the user has customised.
#
# Timing: runs at 45 (after 30-control-plane has created config.yaml and
# the Kanban setup, but before the security-tool components install the
# binaries each MCP server wraps). That's fine -- Hermes spawns MCP
# servers on demand the first time the agent asks for one of their
# tools, by which point base-tools and re have run in the default plan.

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

configure_mcp_servers() {
  local config_path="$HERMES_HOME/config.yaml"
  if [ ! -f "$config_path" ]; then
    fail "$config_path not present; run --only control-plane first"
  fi

  log "Merging mcp_servers into $config_path"
  export SETUP_HERMES_CONFIG_PATH="$config_path"
  python3 - <<'PY'
from pathlib import Path
import os
try:
    import yaml
except Exception as exc:
    raise SystemExit(f'PyYAML required to update config.yaml: {exc}')

p = Path(os.environ['SETUP_HERMES_CONFIG_PATH'])
data = yaml.safe_load(p.read_text(encoding='utf-8')) if p.exists() else {}
if not isinstance(data, dict):
    data = {}

current = data.get('mcp_servers')
if not isinstance(current, dict):
    current = {}

# Defaults we install. Only add entries the user hasn't already configured
# so a per-host customisation (e.g. extra args, disabled flag, env vars)
# isn't reverted on re-run.
defaults = {
    'eip-mcp': {'command': 'eip-mcp', 'enabled': True},
    'semgrep': {'command': 'semgrep', 'args': ['mcp'], 'enabled': True},
    'ghidra':  {'command': 'ghidra-headless-mcp', 'enabled': True},
}
added = []
for name, spec in defaults.items():
    if name not in current:
        current[name] = spec
        added.append(name)

data['mcp_servers'] = current
p.write_text(yaml.safe_dump(data, sort_keys=False), encoding='utf-8')
print('added:', ' '.join(added) if added else '(none -- entries already present)')
PY
  unset SETUP_HERMES_CONFIG_PATH
  success "mcp_servers block ready"
}

restart_hermes_gateway_if_running() {
  if systemctl is-active --quiet hermes-gateway 2>/dev/null; then
    log "Restarting hermes-gateway to pick up new MCP config"
    sudo_cmd systemctl restart hermes-gateway \
      || warn "Could not restart hermes-gateway; new MCP entries take effect on next restart"
  fi
}

# === component entry points ================================================

run() {
  configure_mcp_servers
  restart_hermes_gateway_if_running
}

verify() {
  local config_path="$HERMES_HOME/config.yaml"
  if [ ! -f "$config_path" ]; then
    warn "$config_path not present"
    return 0
  fi
  local name
  for name in eip-mcp semgrep ghidra; do
    if grep -qE "^[[:space:]]+${name}:[[:space:]]*$" "$config_path"; then
      success "mcp_servers has '$name'"
    else
      warn "mcp_servers missing '$name'"
    fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
