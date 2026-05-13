#!/usr/bin/env bash
# eip-hermes-component:
#   name: ai-tools
#   description: Local Ollama LLM runtime + Node.js + Claude Code + Codex CLI agents
#   default: enabled
#   ports: 11434:ollama
#   requires: runtimes
#
# Installs:
#   - Ollama (systemd-managed, bound to 127.0.0.1:11434 by drop-in override)
#   - Node.js 22 LTS via NodeSource (required by Codex; also useful for any
#     future @anthropic-ai/claude-code style npm consumers)
#   - Claude Code CLI from claude.ai/install.sh (per-user, runs as
#     detect_setup_user)
#   - @openai/codex npm global
#
# After install, the user is expected to log in interactively to Codex and
# Claude Code. Honcho is wired (in defaults.env) to talk to local Ollama via
# host.docker.internal:11434; the user must pull at least one model before
# Honcho's memory pipelines will work:
#
#   ollama pull qwen2.5:7b
#   export LLM_MODEL=qwen2.5:7b
#   ./components/40-honcho.sh    # re-apply Honcho config

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

# --------------------------- Ollama -----------------------------------------

install_ollama() {
  if [ "$INSTALL_OLLAMA" != true ]; then warn "Skipping Ollama install"; return 0; fi
  # Re-run the upstream installer if either the binary OR the systemd unit is
  # missing. The unit-presence check matters because a partial previous run
  # (where useradd failed mid-install, e.g. leftover group from a prior
  # teardown) leaves the binary in place but no systemd unit, which then
  # makes `systemctl enable ollama` below fail.
  if need_cmd ollama && [ -e /etc/systemd/system/ollama.service ]; then
    success "ollama already installed: $(ollama --version 2>&1 | head -1)"
  else
    log "Installing Ollama from $OLLAMA_INSTALL_URL"
    curl -fsSL "$OLLAMA_INSTALL_URL" | sudo_cmd sh
    need_cmd ollama || fail "Ollama install completed but ollama is not on PATH"
    [ -e /etc/systemd/system/ollama.service ] || fail "Ollama install completed but the systemd unit is missing at /etc/systemd/system/ollama.service"
    success "Ollama installed: $(ollama --version 2>&1 | head -1)"
  fi

  # Pin Ollama to 127.0.0.1:11434 via systemd drop-in. The Ollama installer
  # leaves OLLAMA_HOST unset, which on some versions binds 0.0.0.0. We want
  # loopback-only by default; users can override via OLLAMA_HOST in env.
  log "Configuring Ollama to bind 127.0.0.1:$OLLAMA_PORT"
  sudo_cmd install -d -m 0755 /etc/systemd/system/ollama.service.d
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Service]
Environment=OLLAMA_HOST=$OLLAMA_HOST:$OLLAMA_PORT
EOF
  sudo_cmd install -m 0644 "$tmp" /etc/systemd/system/ollama.service.d/override.conf
  rm -f "$tmp"
  sudo_cmd systemctl daemon-reload
  sudo_cmd systemctl enable --now ollama
  sudo_cmd systemctl restart ollama
  success "Ollama service running on $OLLAMA_HOST:$OLLAMA_PORT"
}

# --------------------------- Node.js ----------------------------------------

install_node() {
  if [ "$INSTALL_NODE" != true ]; then warn "Skipping Node.js install"; return 0; fi
  if need_cmd node && node --version | grep -qE "^v(${NODE_MAJOR}|$((NODE_MAJOR + 1))|$((NODE_MAJOR + 2)))\."; then
    success "Node.js already installed: $(node --version)"
    return 0
  fi
  log "Installing Node.js $NODE_MAJOR LTS from NodeSource"
  tmp="$(mktemp -d)"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$tmp/nodesource.sh"
  sudo_cmd bash "$tmp/nodesource.sh"
  rm -rf "$tmp"
  sudo_cmd apt-get install -y nodejs
  success "Node.js installed: $(node --version)"
}

# --------------------------- Claude Code ------------------------------------

install_claude_code() {
  if [ "$INSTALL_CLAUDE_CODE" != true ]; then warn "Skipping Claude Code install"; return 0; fi
  local target_user target_home
  target_user="$(detect_setup_user)"
  target_home="$(detect_setup_home "$target_user")"
  [ -n "$target_home" ] || target_home="$HOME"

  if sudo -u "$target_user" -H bash -lc 'command -v claude' >/dev/null 2>&1; then
    local cur
    cur="$(sudo -u "$target_user" -H bash -lc 'claude --version 2>/dev/null' || true)"
    success "Claude Code already installed for $target_user${cur:+: $cur}"
    return 0
  fi

  log "Installing Claude Code CLI for $target_user (home: $target_home)"
  tmp="$(mktemp -d)"
  curl -fsSL "$CLAUDE_INSTALL_URL" -o "$tmp/claude-install.sh"
  if [ "$target_user" = "$(id -un)" ] && [ "$(id -u)" -ne 0 ]; then
    bash -lc "cd '$target_home' && bash -s" <"$tmp/claude-install.sh" || warn "Claude Code install reported errors"
  else
    sudo -u "$target_user" -H bash -lc "cd '$target_home' && bash -s" <"$tmp/claude-install.sh" || warn "Claude Code install reported errors"
  fi
  rm -rf "$tmp"
  if sudo -u "$target_user" -H bash -lc 'command -v claude' >/dev/null 2>&1; then
    success "Claude Code installed for $target_user"
  else
    warn "Claude Code is not on $target_user's PATH yet (may need shell relogin)"
  fi
}

# ---------------------------- Codex -----------------------------------------

install_codex() {
  if [ "$INSTALL_CODEX" != true ]; then warn "Skipping Codex install"; return 0; fi
  if need_cmd codex; then
    success "codex already installed: $(codex --version 2>&1 | head -1)"
    return 0
  fi
  need_cmd npm || fail "npm not found; ensure Node.js is installed before Codex"
  log "Installing @openai/codex globally via npm"
  sudo_cmd npm install -g @openai/codex
  need_cmd codex && success "codex installed: $(codex --version 2>&1 | head -1)" \
    || warn "codex install completed but codex is not on PATH"
}

# --------------------------- Post-install hint ------------------------------

print_login_hint() {
  cat <<EOF

Next: log into the agent CLIs and prepare a model for Honcho.

  Agent CLIs (do these once, in another shell; independent of the model below):
    claude login                              # Anthropic Claude Code
    codex login                               # OpenAI Codex

  Pick a model Honcho will use, one of:

    1. Ollama Cloud (recommended; free signin, no local GPU needed):
         ollama signin
         ollama pull glm-5.1:cloud            # or:
         ollama pull deepseek-v4-pro:cloud    # or:
         ollama pull kimi-k2.6:cloud

    2. Fully local (downloads weights to disk; needs the VRAM/RAM to run them):
         ollama pull qwen2.5:7b

  Honcho will auto-pick the first model 'ollama list' returns. To force a
  specific one, export LLM_MODEL=<name> before re-running --only honcho.
EOF
}

# Hold the installer until the user has pulled at least one Ollama model.
# Without this, 40-honcho runs against an empty Ollama and Hermes ends up wired
# to the .env.template defaults, requiring a manual --only honcho --force
# rerun. Skipped under --non-interactive (CI) and skipped on re-runs where a
# model is already present.
pause_for_model() {
  if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
    return 0
  fi
  if ollama list 2>/dev/null | awk 'NR>1 && $1!=""' | grep -q .; then
    success "Ollama model already present: $(ollama list 2>/dev/null | awk 'NR>1 && $1!="" {print $1; exit}')"
    return 0
  fi
  printf '\nPress ENTER once you have pulled at least one model, or Ctrl+C to abort. ' >&2
  read -r _
}

# === component entry points ================================================

run() {
  install_ollama
  install_node
  install_claude_code
  install_codex
  print_login_hint
  pause_for_model
}

verify() {
  if curl -fsS "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/version" >/dev/null 2>&1; then
    success "Ollama API reachable at http://${OLLAMA_HOST}:${OLLAMA_PORT}"
  else
    warn "Ollama API not reachable at http://${OLLAMA_HOST}:${OLLAMA_PORT}"
  fi
  if need_cmd node; then success "node on PATH: $(node --version)"; else warn "node not on PATH"; fi
  if need_cmd codex; then success "codex on PATH: $(command -v codex)"; else warn "codex not on PATH"; fi
  local target_user
  target_user="$(detect_setup_user)"
  if sudo -u "$target_user" -H bash -lc 'command -v claude' >/dev/null 2>&1; then
    success "claude on $target_user's PATH"
  else
    warn "claude not on $target_user's PATH"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
