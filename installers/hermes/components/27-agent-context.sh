#!/usr/bin/env bash
# eip-hermes-component:
#   name: agent-context
#   description: Seed EIP-specific Hermes identity and compact memory defaults
#   default: enabled
#   ports:
#   requires: hermes,cve-skills
#
# Hermes memory works best when stable identity, compact always-on facts, and
# reusable procedures live in different places. This component seeds only the
# first two: SOUL.md for identity and memories/MEMORY.md for terse environment
# facts. Repeatable CVE workflows belong in the EIP skill library, not in
# MEMORY.md.

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

should_write_context_file() {
  local path="${1:?path required}"
  [ "${SETUP_AGENT_CONTEXT:-true}" = true ] || return 1
  [ "${HERMES_AGENT_CONTEXT_FORCE:-false}" = true ] && return 0
  [ ! -s "$path" ]
}

write_eip_soul() {
  local path="$HERMES_HOME/SOUL.md"
  mkdir -p "$HERMES_HOME"
  if ! should_write_context_file "$path"; then
    warn "$path already exists; preserving it. Use HERMES_AGENT_CONTEXT_FORCE=true to regenerate."
    return 0
  fi

  log "Writing EIP Hermes identity to $path"
  cat >"$path" <<'EOF'
# Soul

You are the EIP Hermes agent for responsible CVE research and lab operations.

Be precise, skeptical, and source-grounded. Prefer reproducible evidence over
speculation. Separate facts, inferences, and open questions. When security
impact is uncertain, say so plainly.

Use the EIP CVE skill library for vulnerability research workflows. Preserve
provenance, cite source URLs or local artifacts, and avoid laundering uncertain
claims into confident conclusions.

For code and installer work, read the relevant files before changing them,
keep edits small, preserve user modifications, and verify with the narrowest
useful command before calling work complete.

Do not run destructive, exploitative, externally visible, or persistence-style
actions without explicit user authorization.
EOF
  chmod 600 "$path"
  success "SOUL.md ready"
}

write_eip_memory() {
  local dir="$HERMES_HOME/memories"
  local path="$dir/MEMORY.md"
  local cve_skills_dir="${CVE_SKILLS_DIR:-$HERMES_HOME/skills/eip-cve}"
  mkdir -p "$dir"
  if ! should_write_context_file "$path"; then
    warn "$path already exists; preserving it. Use HERMES_AGENT_CONTEXT_FORCE=true to regenerate."
    return 0
  fi

  log "Writing compact EIP Hermes memory to $path"
  cat >"$path" <<EOF
EIP Hermes is a dedicated Ubuntu 24.04 research-host installer. Main repo path after clone is eip-hermes; Hermes home is $HERMES_HOME.

Native EIP/Hermes services should bind 127.0.0.1 in 50000-50999. Current defaults: Hermes API 50000, dashboard 50010, Honcho 50040. Exceptions: Ollama 11434 loopback, optional xrdp 3389.

Installed EIP CVE skills live under $cve_skills_dir. Use skills for repeatable CVE/research procedures; keep MEMORY.md for compact facts only.
EOF
  chmod 600 "$path"
  success "MEMORY.md ready"
}

write_user_memory_placeholder() {
  local dir="$HERMES_HOME/memories"
  local path="$dir/USER.md"
  mkdir -p "$dir"
  if [ -e "$path" ]; then
    return 0
  fi
  log "Creating empty user memory placeholder at $path"
  : >"$path"
  chmod 600 "$path"
  success "USER.md placeholder ready"
}

# === component entry points ================================================

run() {
  [ "${SETUP_AGENT_CONTEXT:-true}" = true ] || { warn "Skipping Hermes agent context seed"; return 0; }
  write_eip_soul
  write_eip_memory
  write_user_memory_placeholder
}

verify() {
  [ "${SETUP_AGENT_CONTEXT:-true}" = true ] || return 0
  local missing=0
  for path in "$HERMES_HOME/SOUL.md" "$HERMES_HOME/memories/MEMORY.md" "$HERMES_HOME/memories/USER.md"; do
    if [ -e "$path" ]; then
      success "Hermes context file present: $path"
    else
      warn "Hermes context file missing: $path"
      missing=1
    fi
  done
  return "$missing"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
