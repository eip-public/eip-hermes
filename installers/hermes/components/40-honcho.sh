#!/usr/bin/env bash
# eip-hermes-component:
#   name: honcho
#   description: Local Honcho memory backend (clone, env, compose, start) and Hermes-Honcho bridge config — opt-in via --with honcho
#   default: disabled
#   ports: 50040:honcho-api
#   requires: runtimes,ai-tools,hermes

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

# --------------------------- Auto-detect Ollama model ----------------------
# When LLM_BASE_URL points at the local Ollama installed by ai-tools and the
# user hasn't explicitly set LLM_MODEL, ask Ollama which model to use. Picks
# the first model from `ollama list` (most-recently pulled tends to land
# first). If the user has set LLM_MODEL, leave it alone -- explicit wins.
auto_detect_llm_model() {
  [ -n "$LLM_MODEL" ] && { success "Using explicit LLM_MODEL=$LLM_MODEL"; return 0; }
  case "$LLM_BASE_URL" in
    *host.docker.internal:*|*127.0.0.1:*|*localhost:*) ;;
    *) return 0 ;;
  esac
  if ! need_cmd ollama; then
    warn "LLM_MODEL not set and ollama CLI is missing; Honcho will use the .env.template defaults"
    return 0
  fi
  local detected
  detected="$(ollama list 2>/dev/null | awk 'NR>1 && $1!="" {print $1; exit}')"
  if [ -n "$detected" ]; then
    log "Auto-detected Ollama model: $detected (override with LLM_MODEL)"
    LLM_MODEL="$detected"
    export LLM_MODEL
  else
    warn "ollama list returned no models; pull one with \`ollama pull <name>\` and re-run with --only honcho --force"
  fi
}

prompt_honcho_secret_if_needed() {
  if [ "$SETUP_HONCHO" != true ]; then return 0; fi
  if [ -n "$LLM_API_KEY" ]; then return 0; fi
  if [ "$NON_INTERACTIVE" = true ]; then
    fail "Honcho needs an LLM key. Set OPENAI_API_KEY/LLM_OPENAI_API_KEY or pass --llm-api-key. Use a dummy key for local Ollama."
  fi
  printf 'Enter LLM API key for Honcho (OpenAI/OpenRouter/Ollama dummy; input hidden): ' >&2
  stty -echo; IFS= read -r LLM_API_KEY; stty echo; printf '\n' >&2
  [ -n "$LLM_API_KEY" ] || fail "No LLM API key provided."
}

clone_or_update_honcho() {
  [ "$SETUP_HONCHO" = true ] || return 0
  if [ -d "$HONCHO_DIR/.git" ]; then
    log "Updating Honcho checkout at $HONCHO_DIR"
    git -C "$HONCHO_DIR" fetch origin "$HONCHO_BRANCH" || warn "Could not fetch Honcho branch"
    git -C "$HONCHO_DIR" checkout "$HONCHO_BRANCH" || warn "Could not checkout Honcho branch"
    git -C "$HONCHO_DIR" pull --ff-only origin "$HONCHO_BRANCH" || warn "Could not fast-forward Honcho checkout; leaving existing checkout as-is"
  else
    log "Cloning Honcho into $HONCHO_DIR"
    mkdir -p "$(dirname "$HONCHO_DIR")"
    git clone --branch "$HONCHO_BRANCH" "$HONCHO_REPO_URL" "$HONCHO_DIR"
  fi
  success "Honcho checkout ready"
}

write_honcho_env() {
  [ "$SETUP_HONCHO" = true ] || return 0
  prompt_honcho_secret_if_needed
  cd "$HONCHO_DIR"
  [ -f .env.template ] || fail "Honcho .env.template not found in $HONCHO_DIR"
  if [ -f .env ] && [ "$FORCE" != true ]; then
    warn "$HONCHO_DIR/.env already exists; preserving it. Use --force to regenerate."
    return 0
  fi
  log "Writing Honcho .env"
  cp .env.template .env
  export SETUP_LLM_API_KEY="$LLM_API_KEY" SETUP_LLM_MODEL="$LLM_MODEL" SETUP_LLM_BASE_URL="$LLM_BASE_URL"
  python3 - <<'PY'
from pathlib import Path
import os
path = Path('.env')
lines = path.read_text(encoding='utf-8').splitlines()
updates = {'AUTH_USE_AUTH': 'false', 'LLM_OPENAI_API_KEY': os.environ['SETUP_LLM_API_KEY']}
model = os.environ.get('SETUP_LLM_MODEL', '')
base_url = os.environ.get('SETUP_LLM_BASE_URL', '')
if model:
    for prefix in ('DERIVER', 'DIALECTIC', 'SUMMARY', 'DREAM'):
        updates[f'{prefix}_MODEL_CONFIG__TRANSPORT'] = 'openai'
        updates[f'{prefix}_MODEL_CONFIG__MODEL'] = model
if base_url:
    for prefix in ('DERIVER', 'DIALECTIC', 'SUMMARY', 'DREAM'):
        updates[f'{prefix}_MODEL_CONFIG__OVERRIDES__BASE_URL'] = base_url
managed = set(updates)
kept = []
for line in lines:
    stripped = line.lstrip()
    if stripped and not stripped.startswith('#') and '=' in stripped and stripped.split('=',1)[0].strip() in managed:
        continue
    kept.append(line)
def quote_env(v: str) -> str:
    return "'" + v.replace("'", "'\\''") + "'"
kept += ['', '# --- Added by Ultimate Hermes setup: Honcho ---']
for k, v in updates.items(): kept.append(f'{k}={quote_env(v)}')
path.write_text('\n'.join(kept) + '\n', encoding='utf-8')
PY
  unset SETUP_LLM_API_KEY SETUP_LLM_MODEL SETUP_LLM_BASE_URL
  chmod 600 .env
  success "Honcho .env written"
}

write_honcho_compose() {
  [ "$SETUP_HONCHO" = true ] || return 0
  cd "$HONCHO_DIR"
  if [ -f docker-compose.yml ] && [ "$FORCE" != true ]; then
    warn "$HONCHO_DIR/docker-compose.yml already exists; preserving it. Use --force to regenerate."
    return 0
  fi
  [ -f docker-compose.yml.example ] || fail "docker-compose.yml.example not found in $HONCHO_DIR"
  cp docker-compose.yml.example docker-compose.yml
  if [ -z "$HOST_DNS_SERVER" ] && need_cmd resolvectl; then
    HOST_DNS_SERVER="$(resolvectl dns 2>/dev/null | awk '/^Link / && $NF ~ /^[0-9]+(\.[0-9]+){3}$/ {print $NF; exit}')"
  fi
  export SETUP_HOST_DNS_SERVER="$HOST_DNS_SERVER" SETUP_HONCHO_API_PORT="$HONCHO_API_PORT"
  python3 - <<'PY'
from pathlib import Path
import os
path = Path('docker-compose.yml')
text = path.read_text(encoding='utf-8')
if 'network: host' not in text:
    text = text.replace('    build:\n      context: .\n      dockerfile: Dockerfile', '    build:\n      context: .\n      dockerfile: Dockerfile\n      network: host')
if 'host.docker.internal:host-gateway' not in text:
    lines = text.splitlines(); out = []; host_dns = os.environ.get('SETUP_HOST_DNS_SERVER', '')
    for line in lines:
        out.append(line)
        if line in ('  api:', '  deriver:'):
            if host_dns:
                out += ['    dns:', f'      - "{host_dns}"', '    dns_search:', '      - "."', '    dns_opt:', '      - "ndots:1"']
            out += ['    extra_hosts:', '      - "host.docker.internal:host-gateway"']
    text = '\n'.join(out) + '\n'
lines = text.splitlines(); out = []; current = None; i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith('  ') and not line.startswith('    ') and line.endswith(':'):
        current = line.strip().rstrip(':')
    if line == '    ports:':
        if current == 'api':
            api_port = os.environ.get('SETUP_HONCHO_API_PORT', '50040')
            out.append(line)
            out.append(f'      - "127.0.0.1:{api_port}:8000"')
            i += 1
            while i < len(lines) and lines[i].startswith('      '): i += 1
            continue
        if current in {'database', 'redis'}:
            out.append('    # ports intentionally not published by Ultimate Hermes setup to avoid host conflicts')
            i += 1
            while i < len(lines) and lines[i].startswith('      '): i += 1
            continue
    out.append(line); i += 1
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
  success "Honcho docker-compose.yml ready"
}

start_honcho() {
  [ "$SETUP_HONCHO" = true ] || return 0
  if [ "$START_STACKS" != true ]; then warn "Skipping Honcho start"; return 0; fi
  log "Starting Honcho stack; first source build may take several minutes"
  cd "$HONCHO_DIR"
  docker compose up -d --build
  log "Waiting for Honcho health endpoint"
  for _ in $(seq 1 90); do
    if curl -fsS "$HONCHO_BASE_URL/health" >/dev/null 2>&1; then
      success "Honcho API is healthy at $HONCHO_BASE_URL"
      docker compose ps
      return 0
    fi
    sleep 2
  done
  docker compose ps || true; docker compose logs api --tail 80 || true
  fail "Honcho did not become healthy at $HONCHO_BASE_URL/health"
}

configure_hermes_honcho() {
  [ "$SETUP_HONCHO" = true ] || return 0
  [ "$CONFIGURE_HERMES" = true ] || { warn "Skipping Hermes Honcho config"; return 0; }
  mkdir -p "$HERMES_HOME"
  local config_path="$HERMES_HOME/honcho.json"
  if [ -f "$config_path" ] && [ "$FORCE" != true ]; then
    warn "$config_path already exists; preserving it. Use --force to regenerate."
  else
    log "Writing Hermes Honcho config to $config_path"
    export SETUP_HONCHO_CONFIG_PATH="$config_path"
    export SETUP_HONCHO_BASE_URL="$HONCHO_BASE_URL" SETUP_HONCHO_WORKSPACE="$HONCHO_WORKSPACE" SETUP_HONCHO_USER_PEER="$HONCHO_USER_PEER" SETUP_HONCHO_AI_PEER="$HONCHO_AI_PEER"
    export SETUP_HONCHO_CONTEXT_CADENCE="$HONCHO_CONTEXT_CADENCE" SETUP_HONCHO_DIALECTIC_CADENCE="$HONCHO_DIALECTIC_CADENCE" SETUP_HONCHO_DIALECTIC_DEPTH="$HONCHO_DIALECTIC_DEPTH"
    export SETUP_HONCHO_RECALL_MODE="$HONCHO_RECALL_MODE" SETUP_HONCHO_SESSION_STRATEGY="$HONCHO_SESSION_STRATEGY" SETUP_HONCHO_DIALECTIC_REASONING_LEVEL="$HONCHO_DIALECTIC_REASONING_LEVEL"
    python3 - <<'PY'
import json, os
path = os.environ['SETUP_HONCHO_CONFIG_PATH']
config = {
  'baseUrl': os.environ['SETUP_HONCHO_BASE_URL'],
  'workspace': os.environ['SETUP_HONCHO_WORKSPACE'],
  'peerName': os.environ['SETUP_HONCHO_USER_PEER'],
  'contextCadence': int(os.environ['SETUP_HONCHO_CONTEXT_CADENCE']),
  'dialecticCadence': int(os.environ['SETUP_HONCHO_DIALECTIC_CADENCE']),
  'dialecticDepth': int(os.environ['SETUP_HONCHO_DIALECTIC_DEPTH']),
  'hosts': {'hermes': {
    'enabled': True,
    'aiPeer': os.environ['SETUP_HONCHO_AI_PEER'],
    'recallMode': os.environ['SETUP_HONCHO_RECALL_MODE'],
    'sessionStrategy': os.environ['SETUP_HONCHO_SESSION_STRATEGY'],
    'writeFrequency': 'async',
    'saveMessages': True,
    'dialecticReasoningLevel': os.environ['SETUP_HONCHO_DIALECTIC_REASONING_LEVEL'],
    'observationMode': 'directional',
  }}
}
with open(path, 'w', encoding='utf-8') as f:
    json.dump(config, f, indent=2); f.write('\n')
PY
    chmod 600 "$config_path"
    success "Wrote $config_path"
  fi
  if need_cmd hermes; then
    log "Enabling Honcho memory provider in Hermes config"
    hermes config set memory.provider honcho || warn "Could not set memory.provider with hermes config; edit config.yaml manually."
    hermes memory status || true
  else
    warn "hermes command not found; manually set memory.provider to honcho after Hermes is on PATH."
  fi
}

# === component entry points ================================================

run() {
  # Docker group bootstrap: if the user was added to the docker group by an
  # earlier component (10-runtimes) but the current process tree was forked
  # before that membership existed, /var/run/docker.sock is unreachable. Run
  # this component as a subprocess under `sg docker` so it inherits the new
  # group. Subprocess only -- never `exec` here, that would replace the
  # orchestrator and abort the rest of the run.
  if ! docker info >/dev/null 2>&1; then
    local me; me="$(id -un)"
    if getent group docker 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$me"; then
      log "Picking up docker group membership via sg(1) for honcho"
      sg docker -c "bash '$COMPONENT_DIR/40-honcho.sh'"
      return $?
    fi
  fi

  auto_detect_llm_model
  require_clean_checkout "$HONCHO_DIR"
  clone_or_update_honcho
  write_honcho_env
  write_honcho_compose
  # When regenerating env on an already-running stack, force-recreate so api
  # and deriver containers pick up the new LLM_MODEL/LLM_OPENAI_API_KEY.
  if [ "$FORCE" = true ] && [ -d "$HONCHO_DIR" ]; then
    log "FORCE=true: bringing existing Honcho stack down so new env is picked up on restart"
    (cd "$HONCHO_DIR" && docker compose down 2>/dev/null) || true
  fi
  start_honcho
  configure_hermes_honcho
}

verify() {
  if curl -fsS "$HONCHO_BASE_URL/health" >/dev/null 2>&1; then
    success "Honcho API healthy at $HONCHO_BASE_URL"
  else
    warn "Honcho API health check failed at $HONCHO_BASE_URL"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
