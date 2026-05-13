#!/usr/bin/env bash
# eip-hermes-component:
#   name: control-plane
#   description: Hermes API gateway, dashboard, Kanban, env/config; systemd units; health verify
#   default: enabled
#   ports: 50000:hermes-api,50010:hermes-dashboard
#   requires: hermes
#
# Note: the extracted bodies of install_hermes_control_plane_services and
# verify_hermes_control_plane retain their mcpo branches for byte-identical
# parity with upstream. INSTALL_MCPO defaults to false in defaults.env, so
# those branches are dead code at runtime.

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

configure_hermes_control_plane() {
  [ "$SETUP_HERMES_CONTROL_PLANE" = true ] || return 0
  [ "$CONFIGURE_HERMES" = true ] || { warn "Skipping Hermes control-plane config"; return 0; }
  mkdir -p "$HERMES_HOME"
  local env_path="$HERMES_HOME/.env"
  local config_path="$HERMES_HOME/config.yaml"
  local api_key=""
  if [ -f "$env_path" ]; then
    api_key="$(awk -F= '/^API_SERVER_KEY=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$env_path" || true)"
  fi
  [ -n "$api_key" ] || api_key="$(rand_hex 32)"
  export SETUP_HERMES_ENV_PATH="$env_path" SETUP_HERMES_API_HOST="$HERMES_API_HOST" SETUP_HERMES_API_PORT="$HERMES_API_PORT" SETUP_HERMES_API_KEY="$api_key"
  python3 - <<'PY'
from pathlib import Path
import os
p = Path(os.environ['SETUP_HERMES_ENV_PATH'])
lines = p.read_text(encoding='utf-8').splitlines() if p.exists() else []
updates = {
    'API_SERVER_ENABLED': 'true',
    'API_SERVER_HOST': os.environ['SETUP_HERMES_API_HOST'],
    'API_SERVER_PORT': os.environ['SETUP_HERMES_API_PORT'],
    'API_SERVER_KEY': os.environ['SETUP_HERMES_API_KEY'],
}
out = []
seen = set()
for line in lines:
    stripped = line.lstrip()
    if stripped and not stripped.startswith('#') and '=' in stripped:
        key = stripped.split('=', 1)[0].strip()
        if key in updates:
            out.append(f'{key}={updates[key]}')
            seen.add(key)
            continue
    out.append(line)
if out and out[-1] != '':
    out.append('')
out.append('# --- Added by Ultimate Hermes setup: API Server / Open WebUI ---')
for key, val in updates.items():
    if key not in seen:
        out.append(f'{key}={val}')
p.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
  chmod 600 "$env_path"
  success "Hermes API server env ready at $env_path (key preserved/generated; not printed)"

  export SETUP_HERMES_CONFIG_PATH="$config_path" SETUP_KANBAN_INTERVAL="$HERMES_KANBAN_DISPATCH_INTERVAL"
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
kanban = data.setdefault('kanban', {})
kanban['dispatch_in_gateway'] = True
kanban['dispatch_interval_seconds'] = int(os.environ['SETUP_KANBAN_INTERVAL'])
# Kanban CLI/DB can be configured while the agent-facing kanban tools remain
# unavailable. Doctor checks the toolset gate, so preserve existing toolsets and
# add kanban explicitly for orchestrator/control-plane sessions.
toolsets = data.get('toolsets')
if not isinstance(toolsets, list):
    toolsets = []
for name in ('hermes-cli', 'kanban'):
    if name not in toolsets:
        toolsets.append(name)
data['toolsets'] = toolsets
p.write_text(yaml.safe_dump(data, sort_keys=False), encoding='utf-8')
PY
  success "Hermes Kanban gateway dispatch and toolset configured"

  if need_cmd hermes; then
    hermes kanban init || true
    hermes kanban boards create "$HERMES_KANBAN_BOARD" \
      --name "$HERMES_KANBAN_BOARD_NAME" \
      --description "$HERMES_KANBAN_BOARD_DESCRIPTION" \
      --icon 🤖 \
      --switch >/dev/null 2>&1 || true
    hermes kanban boards switch "$HERMES_KANBAN_BOARD" || true
    hermes kanban boards show || true
  else
    warn "hermes command not found; Kanban board will need manual initialization."
  fi
}

install_hermes_control_plane_services() {
  [ "$SETUP_HERMES_CONTROL_PLANE" = true ] || return 0
  [ "$START_STACKS" = true ] || { warn "Skipping Hermes control-plane service start"; return 0; }
  local setup_user setup_home gateway_cmd mcpo_cmd
  setup_user="$(detect_setup_user)"
  setup_home="$(detect_setup_home "$setup_user")"
  [ -n "$setup_home" ] || setup_home="$HOME"
  if [ -x "$HERMES_INSTALL_DIR/venv/bin/python" ]; then
    gateway_cmd="$HERMES_INSTALL_DIR/venv/bin/python -m hermes_cli.main gateway run --replace"
  else
    gateway_cmd="$(command -v hermes 2>/dev/null || printf hermes) gateway run --replace"
  fi
  mcpo_cmd="$(command -v mcpo 2>/dev/null || printf mcpo) --host $HERMES_MCP_OPENAPI_HOST --port $HERMES_MCP_OPENAPI_PORT --hot-reload --config $MCPO_CONFIG_PATH"

  log "Installing systemd services for Hermes gateway/dashboard/mcpo"
  tmpdir="$(mktemp -d)"
  cat >"$tmpdir/hermes-gateway.service" <<EOF
[Unit]
Description=Hermes Agent Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$setup_user
Group=$setup_user
WorkingDirectory=$HERMES_INSTALL_DIR
Environment=HOME=$setup_home
Environment=HERMES_HOME=$HERMES_HOME
Environment=VIRTUAL_ENV=$HERMES_INSTALL_DIR/venv
Environment=PATH=$HERMES_INSTALL_DIR/venv/bin:/usr/local/bin:$setup_home/.local/bin:/usr/bin:/bin
ExecStart=$gateway_cmd
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat >"$tmpdir/hermes-dashboard.service" <<EOF
[Unit]
Description=Hermes Agent Dashboard
After=network-online.target hermes-gateway.service
Wants=network-online.target

[Service]
Type=simple
User=$setup_user
Group=$setup_user
WorkingDirectory=$setup_home
Environment=HOME=$setup_home
Environment=HERMES_HOME=$HERMES_HOME
Environment=PATH=/usr/local/bin:$setup_home/.local/bin:/usr/bin:/bin
ExecStart=$(command -v hermes 2>/dev/null || printf hermes) dashboard --host $HERMES_DASHBOARD_HOST --port $HERMES_DASHBOARD_PORT --no-open
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  cat >"$tmpdir/mcpo.service" <<EOF
[Unit]
Description=mcpo MCP OpenAPI bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$setup_user
Group=$setup_user
WorkingDirectory=$setup_home
Environment=HOME=$setup_home
Environment=PATH=/usr/local/bin:$setup_home/.local/bin:/usr/bin:/bin
ExecStart=$mcpo_cmd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  sudo_cmd install -m 0644 "$tmpdir/hermes-gateway.service" /etc/systemd/system/hermes-gateway.service
  sudo_cmd install -m 0644 "$tmpdir/hermes-dashboard.service" /etc/systemd/system/hermes-dashboard.service
  if [ "$INSTALL_MCPO" = true ]; then
    sudo_cmd install -m 0644 "$tmpdir/mcpo.service" /etc/systemd/system/mcpo.service
  fi
  rm -rf "$tmpdir"
  sudo_cmd systemctl daemon-reload
  sudo_cmd systemctl enable hermes-gateway hermes-dashboard >/dev/null
  if [ "$INSTALL_MCPO" = true ]; then sudo_cmd systemctl enable mcpo >/dev/null; fi
  sudo_cmd systemctl restart hermes-gateway hermes-dashboard
  if [ "$INSTALL_MCPO" = true ]; then sudo_cmd systemctl restart mcpo; fi
  success "Hermes control-plane services installed and restarted"
}

verify_hermes_control_plane() {
  [ "$SETUP_HERMES_CONTROL_PLANE" = true ] || return 0
  [ "$START_STACKS" = true ] || return 0
  log "Verifying Hermes API, dashboard, Kanban, and mcpo endpoints"
  curl -fsS "http://$HERMES_API_HOST:$HERMES_API_PORT/health" >/dev/null && success "Hermes API health OK at http://$HERMES_API_HOST:$HERMES_API_PORT/health" || warn "Hermes API health check failed"
  curl -fsS "http://$HERMES_DASHBOARD_HOST:$HERMES_DASHBOARD_PORT/api/status" >/dev/null && success "Hermes dashboard OK at http://$HERMES_DASHBOARD_HOST:$HERMES_DASHBOARD_PORT" || warn "Hermes dashboard check failed"
  if [ "$INSTALL_MCPO" = true ]; then
    curl -fsS "http://$HERMES_MCP_OPENAPI_HOST:$HERMES_MCP_OPENAPI_PORT/openapi.json" >/dev/null && success "mcpo OpenAPI bridge OK at http://$HERMES_MCP_OPENAPI_HOST:$HERMES_MCP_OPENAPI_PORT/docs" || warn "mcpo OpenAPI check failed"
  fi
  if need_cmd hermes; then hermes kanban boards show || true; fi
}

# === component entry points ================================================

run() {
  configure_hermes_control_plane
  install_hermes_control_plane_services
  # Give the freshly-restarted gateway/dashboard a moment to bind ports before
  # the orchestrator's verify() runs. Without this, the upstream verify calls
  # curl while systemd is still starting the services and emits spurious
  # health-check failures.
  log "Waiting up to 30s for control-plane services to bind their ports"
  for _ in $(seq 1 30); do
    if curl -fsS -m 1 "http://${HERMES_API_HOST}:${HERMES_API_PORT}/health" >/dev/null 2>&1 \
       && curl -fsS -m 1 "http://${HERMES_DASHBOARD_HOST}:${HERMES_DASHBOARD_PORT}/api/status" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
}

verify() {
  verify_hermes_control_plane
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
