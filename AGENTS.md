# Working in eip-hermes

This is the Hermes-readable project guide. `CLAUDE.md` has the fuller
contributor notes; keep this file concise and focused on rules Hermes should
load while working in the repo.

## Project Shape

`eip-hermes` is a modular bash installer for a dedicated Ubuntu 24.04 Hermes
research host. It installs the Hermes control plane, Honcho memory, Ollama,
agent CLIs, the EIP CVE skill library, MCP wiring, security tools, and optional
lab/desktop extras.

The installer is not the runtime. Runtime state lives under the install user's
`~/.hermes`; this repo should remain an idempotent bring-up layer.

## Hard Rules

- Components in `installers/hermes/components/` are sourced by
  `installers/hermes/install.sh`. Do not call `exit` inside `run()`; return
  status so the orchestrator can continue or fail correctly.
- Use the standard bootstrap guard from `components/TEMPLATE.sh`: check for the
  `need_cmd` function, then source `lib/common.sh` and `defaults.env`.
- Components that need root should re-exec themselves as a sudo subprocess and
  `return $?`; do not replace the orchestrator process.
- Before updating user-editable git checkouts, call
  `require_clean_checkout "$DIR"` so local edits are not silently overwritten.
- Native services must bind `127.0.0.1` in `50000-50999`. Existing exceptions:
  Ollama `11434` loopback, optional xrdp `3389`.
- `bootstrap-user.sh` is the only script that writes sudoers configuration.
- Keep Hermes context layered correctly: `SOUL.md` for stable identity,
  `memories/MEMORY.md` for compact always-on facts, `memories/USER.md` for
  learned user preferences, and skills for repeatable procedures.

## Validation

Run the reviewer checks from `CLAUDE.md` before committing. At minimum:

```bash
./installers/hermes/install.sh --validate
./installers/hermes/install.sh --dry-run
shellcheck -x --exclude=SC1091,SC2034,SC2317,SC2068,SC2015,SC2024 \
  bootstrap-user.sh \
  installers/hermes/install.sh \
  installers/hermes/lib/*.sh \
  installers/hermes/components/*.sh
```

On macOS, `/bin/bash` is often Bash 3.2 and cannot run `install.sh` because it
uses `mapfile`. Use Ubuntu 24.04 or another Bash 4+ environment for
orchestrator validation.
