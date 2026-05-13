# Working in eip-hermes

Project-level notes for anyone -- human or AI -- making changes here.
This file is the source of truth for the conventions the rest of the repo
holds itself to. Read it first.

## What this repo is

A modular bash installer that brings up the Hermes AI agent platform on
Ubuntu 24.04 -- control plane (gateway/dashboard/Kanban + Honcho memory
+ local Ollama), CVE skill library, MCP server wiring, security
toolchain, and two opt-in extras (XFCE+xrdp, Win11 lab host).

It is **not** a runtime tool. It is a one-time/idempotent installer.
Components that wrap runtime tools (e.g. `win11-forge`) clone or
reference them; they don't reimplement them.

## Where things live

```
bootstrap-user.sh                  one-time, with sudo: grants the current user passwordless sudo
AGENTS.md                          concise Hermes-readable project guide
installers/hermes/
  install.sh                       drop-in component orchestrator
  components/NN-<name>.sh          18 components, numeric-prefix order
  lib/common.sh                    log/success/warn/fail, sudo_cmd, prepend_path,
                                   require_clean_checkout
  lib/security-tools.sh            shared globals/helpers for the security-tool
                                   components (50-* … 85-*); intentionally
                                   overrides common.sh's log/warn/die with the
                                   upstream `==>` prefix style
  defaults.env                     env-var defaults; everything is overridable
  PORTS.md                         port registry
  README.md                        user-facing quickstart + component table
  components/TEMPLATE.sh           contributor template
CONTRIBUTING.md                    add-a-component walkthrough
README.md                          high-level intro for the repo's front page
```

## Hard rules

These are the invariants the existing code relies on. Don't break them.

1. **Components are sourced, not exec'd, by the orchestrator.** So
   nothing in a component may call `exit` from inside `run()` unless
   you intend to kill the orchestrator. Use `return $?`. The corollary:
   when a component needs root, re-exec the file as a subprocess:

   ```bash
   run() {
     if [ "$(id -u)" -ne 0 ]; then
       sudo -E bash "$COMPONENT_DIR/<this-file>.sh"
       return $?
     fi
     ...
   }
   ```

   `return $?` exits `run()` with the subprocess's status; the
   orchestrator's `set -e` propagates failure correctly. **Never `exit`
   from this branch.**

2. **Bootstrap guard checks function presence, not an env var.** Every
   component starts with:

   ```bash
   if ! declare -f need_cmd >/dev/null 2>&1; then
     source "$INSTALLER_DIR/lib/common.sh"
     set -a; source "$INSTALLER_DIR/defaults.env"; set +a
   fi
   ```

   An exported env-var guard would cross `sudo -E` process boundaries
   and skip the bootstrap in subprocesses where the functions aren't
   actually defined -- that was the cause of a real failure earlier
   in the project's history. Function presence is process-local and
   right in every mode (orchestrator, standalone, sudo'd subprocess).

3. **Re-running an install must not silently overwrite local mods.**
   Any component that does `git pull --ff-only` on a user-editable
   checkout calls `require_clean_checkout "$DIR"` from `lib/common.sh`
   beforehand. Currently used by `20-hermes`, `25-cve-skills`,
   `40-honcho`, `91-lab-host`.

4. **Native services bind `127.0.0.1` on ports `50000-50999`.** See
   `installers/hermes/PORTS.md`. Two documented exceptions only:
   Ollama on `11434` (third-party well-known port, loopback-bound) and
   xrdp on `3389/tcp` (the RDP standard; the user fronts it with SSH
   tunnel or firewall). Don't add new exceptions without updating
   PORTS.md and the README.

5. **Privilege escalation is explicit.** `bootstrap-user.sh` is
   the only thing that writes a sudoers fragment. It runs once, with
   sudo, and validates with `visudo -cf` before installing. The main
   installer never writes sudoers.

6. **No surprise destructive ops.** Don't write commands that double
   as "diagnostics + side effects." If a command reboots, force-pushes,
   deletes things, or downloads large assets, the user must have
   approved that specific action.

7. **Keep Hermes context in the right layer.** `SOUL.md` is for stable
   identity and safety posture. `memories/MEMORY.md` is for compact
   always-on facts. `memories/USER.md` is for user preferences learned
   from real interactions. Repeatable procedures belong in skills, not
   in memory files.

## Validation before commit

```bash
./installers/hermes/install.sh --validate        # component metadata lint
./installers/hermes/install.sh --dry-run         # default plan resolves
./installers/hermes/install.sh --with rdp,lab-host --dry-run
shellcheck -x --exclude=SC1091,SC2034,SC2317,SC2068,SC2015,SC2024 \
  bootstrap-user.sh \
  installers/hermes/install.sh \
  installers/hermes/lib/*.sh \
  installers/hermes/components/*.sh
```

The `--exclude` codes are documented at the bottom of
`installers/hermes/lib/security-tools.sh` and are intentional: they fire
inside extracted upstream blocks where rewriting the construct would
churn more than it's worth.

## Adding a new component

`CONTRIBUTING.md` has the full walkthrough. The short version:

1. Copy `installers/hermes/components/TEMPLATE.sh` to
   `components/NN-<name>.sh` (next unused numeric prefix).
2. Fill in the metadata header (`name`, `description`, `default`,
   `ports`, `requires`).
3. Implement `run()` and `verify()`. If you need root, use the
   sudo-re-exec pattern from rule 2.
4. Add env-var defaults to `defaults.env` and any new listening port
   to `PORTS.md`.
5. Update `installers/hermes/README.md`'s component table.
6. Run the validation block above.

## Style

- `set -Eeuo pipefail` at the top of every shell script.
- Use `lib/common.sh` helpers. Override them only in
  `lib/security-tools.sh` (already done), where the upstream prefix
  style needs to be preserved.
- Comment the *why*, not the *what*. The code already says what it
  does; only annotate non-obvious constraints, workarounds, and
  deliberate deviations.

## Where the runtime lives

Hermes runs as the install user (per-user `$HOME/.hermes`). The
`hermes-gateway` and `hermes-dashboard` systemd units the
`30-control-plane` component installs run with `User=$TARGET_USER`,
`HOME=$TARGET_HOME`, and the right venv on `PATH`.

`sudo hermes ...` will **not** work -- `sudo` resets `PATH` and `HOME`,
and the per-user `hermes` launcher then can't find its config. To
manage the services, talk to systemd directly:

```bash
sudo systemctl restart hermes-gateway
sudo systemctl restart hermes-dashboard
```

## Documentation hierarchy

When updating docs:

- Top-level `README.md` -- high-level intro, layout, design principles,
  what's in scope vs out. Don't duplicate the component list (lives in
  the installer README).
- `installers/hermes/README.md` -- canonical component list, full
  quickstart, configuration, skip/with/only flags, operations.
- `installers/hermes/PORTS.md` -- port registry. Adding a new listening
  port? It goes here, not in folklore.
- `CONTRIBUTING.md` -- contributor flow.
- `AGENTS.md` -- concise Hermes-readable project guidance.
- `CLAUDE.md` (this file) -- fuller contributor/AI-agent notes and the
  invariants the code holds itself to.

If a fact lives in two places, the two will drift. Pick the right home
for it and link from the other.
