# `installers/hermes`

Modular installer for the Hermes Agent control plane on Ubuntu 24.04. Drop-in
component system: each step is one self-contained script in `components/`,
the orchestrator (`install.sh`) discovers them by filename order, parses
their metadata header, and runs them with dependency resolution.

## Before you install

Read this before running anything. The default plan is large.

### Host

- **Ubuntu 24.04** (or noble derivative). The `preflight` component
  refuses to proceed otherwise; pass `ALLOW_UNSUPPORTED=1` only if
  you really know what you're doing.
- **CPU virtualization** enabled in BIOS (Intel VT-x / AMD-V). If
  this host will itself be a VM, **nested virtualization must be
  exposed by the outer hypervisor** — otherwise the KVM-backed
  Windows labs in win11-forge will not run.
- **Disk**: plan for **~120 GB used** after the full install,
  including the win11-forge KVM and VMware gold images. The root
  filesystem must have room for that — Ubuntu Server's default
  partitioning leaves most of the disk unallocated in the VG; the
  `disk-expand` component grows the root LV into that free space,
  but only what the VG actually has.
- **RAM**: **32 GB** if you intend to run Windows VMs in the labs.
  **8 GB** is workable if you skip win11-forge and manage Docker
  labs conservatively (`--skip lab-host`, fewer container labs).
- **Network**: the install downloads roughly **50 GB** across apt
  repositories (Docker, Brave, GitHub CLI, Metasploit), pipx/npm
  registries, Ollama models, Go/Gradle, Ghidra, Burp, MS symbol
  server URLs, and the Hermes/Honcho/win11-forge git clones. No
  offline install path is supported today.

### Account and sudo

- Run as **the user that will own Hermes long-term**, not root and
  not a throwaway account. `bootstrap-user.sh` grants that user
  passwordless sudo permanently; `install.sh` and the agents
  inherit it.
- Regular `sudo` must already be working before you run
  `bootstrap-user.sh` (it uses sudo to install the sudoers fragment).

### What this is not

This is a fresh-host, dedicated-research-machine install. The
default plan disables sleep/lid handling, opens Docker to the user's
group, clones agent runtimes into `$HOME`, and installs xrdp on
`0.0.0.0:3389` (skip with `--skip rdp` for headless). **Do not run on a shared
workstation, a laptop you also use for production, or a host that's
reachable from anything you don't trust.** See
[`SECURITY.md`](../../SECURITY.md).

## Quickstart

The installer runs as a **non-root user with passwordless sudo**. Logged in
as the user that will run hermes, grant that sudo grant once with the
bootstrap script, then run the installer:

```bash
sudo ../../bootstrap-user.sh                   # one-time: NOPASSWD sudoers entry for $SUDO_USER
./install.sh                                   # full install -- see "What gets installed" below
```

### What to expect

- **Interactive by default.** Some components prompt (apt, Docker
  install, the `claude` / `codex` CLIs reserve their interactive
  logins for *after* the install — see "Confirming the install
  worked" below). Pass `--non-interactive` if you want apt and
  similar to accept defaults silently.
- **Downloads are large.** The full plan pulls ~50 GB across apt
  repositories, pipx/npm registries, Ollama, Go/Gradle, Ghidra, Burp
  Community, and three git clones. Plan for the network spend.
- **Idempotent.** Every component detects already-installed state
  and skips. If the run fails mid-way (apt mirror flake, network
  drop, a single component erroring), fix the cause and re-run
  `./install.sh` — completed components no-op, partially-done ones
  resume safely. Use `--force` only when you want managed config
  files regenerated.
- **One component at a time.** Components run sequentially in prefix
  order; if one fails the orchestrator stops there with the failing
  component's name in the log. Re-run after fixing, or skip past it
  with `--skip <name>` and come back.

Other useful invocations once you've run it once:

```bash
./install.sh --list                           # show every component, default state, ports, requires
./install.sh --only honcho --dry-run          # see what would run if you only re-did honcho
./install.sh --skip honcho                    # everything except honcho
./install.sh --non-interactive --force        # CI-friendly; regenerate managed config files
./components/40-honcho.sh                     # re-run a single component standalone
```

## What gets installed

The default plan runs all enabled components in numeric prefix order.

### Hermes control plane (00–40)

| Component       | What it does                                                                  | Ports        |
|-----------------|-------------------------------------------------------------------------------|--------------|
| `preflight`     | Verifies Ubuntu 24.04 / noble derivative; checks passwordless sudo            | --            |
| `disk-expand`   | Grows the root LV into any free VG space (Ubuntu Server leaves most of the disk unallocated). No-op on non-LVM or already-full VGs. Skip with `--skip disk-expand`. | -- |
| `runtimes`      | apt prerequisites, Docker Engine + Compose, `uv`                              | --            |
| `ai-tools`      | Local Ollama LLM runtime, Node.js, Claude Code CLI, Codex CLI                 | 11434        |
| `hermes`        | Native Hermes Agent install/update from `NousResearch/hermes-agent`           | --            |
| `cve-skills`    | Clones `eip-public/security-skills` into `~/.hermes/skills/eip-cve` so Hermes loads the CVE routing-doctrine skill library | -- |
| `agent-context` | Seeds EIP-specific `SOUL.md`, compact `MEMORY.md`, and an empty `USER.md` placeholder without overwriting existing context | -- |
| `control-plane` | Hermes API gateway + dashboard + Kanban env/config; systemd units; verify     | 50000, 50010 |
| `mcp-config`    | Registers `eip-mcp`, `semgrep`, and `ghidra-headless-mcp` MCP servers in `~/.hermes/config.yaml` so the cve-skills can call their tools | -- |

### Security tooling (50–85)

| Component       | Tools installed                                                               |
|-----------------|-------------------------------------------------------------------------------|
| `base-tools`    | Big apt set (radare2, nmap, hashcat, sqlmap, gdb, qemu, php/ruby, openjdk, etc.); external apt repos (Docker, Brave, GitHub CLI, Metasploit); npm globals; pipx tools (semgrep, eip-mcp, mitmproxy, ropper, ropgadget, frida, uv, mcpo); lazydocker + ctop; `/etc/profile.d/eip-tools.sh` |
| `recon`         | ffuf, nuclei, masscan                                                         |
| `web`           | wp-cli, ysoserial, Burp Suite Community                                       |
| `mobile`        | apktool, jadx, apkeep                                                         |
| `runtime-langs` | Go, Gradle, CodeQL CLI + cpp-queries pack                                     |
| `re`            | Ghidra, BinExport, BinDiff, winbindex, ghidra-headless-mcp                    |
| `exploit-dev`   | pwndbg, syzkaller (`syz-manager`), one_gadget                                 |

### Desktop (90)

Default-enabled. Skip with `--skip rdp` for a strict headless install:

| Component  | What it does                                                                                                  |
|------------|---------------------------------------------------------------------------------------------------------------|
| `rdp`      | XFCE4 desktop + xfce4-terminal (set as default x-terminal-emulator) + xrdp (port 3389, 0.0.0.0). Disables suspend/lid in logind. Front with SSH tunnel or host firewall — don't expose `:3389` directly. |

### Lab integration (91)

Default-enabled. Skip with `--skip lab-host`:

| Component  | What it does                                                                                                  |
|------------|---------------------------------------------------------------------------------------------------------------|
| `lab-host` | Clones `eip-public/win11-forge` into `$WINFORGE_DIR` (default `~/win11-forge`). The heavy lab dependencies (KVM/libvirt/qemu/ovmf, ghidriff, BinExport, Win11/virtio ISOs) are **not** installed here -- run `~/win11-forge/install-deps.sh` yourself when you want to actually build a lab. |

### Optional extras

`default: disabled`; add with `--with NAME[,...]`:

| Component  | What it does                                                                                                  |
|------------|---------------------------------------------------------------------------------------------------------------|
| `honcho`   | Local Honcho memory backend (clone, env, compose, start) + Hermes-Honcho bridge (port 50040). `./install.sh --with honcho`. |

All native services bind to `127.0.0.1` (xrdp is the documented
`0.0.0.0` exception). See [PORTS.md](PORTS.md) for the registry
and rationale.

## Configuration

Defaults live in [`defaults.env`](defaults.env). Override anything by exporting
the var before running `install.sh`:

```bash
HERMES_BRANCH=develop \
HONCHO_API_PORT=50041 \
LLM_OPENAI_API_KEY=ollama \
LLM_BASE_URL=http://host.docker.internal:11434/v1 \
LLM_MODEL=qwen2.5:14b \
sudo -E ./install.sh --non-interactive
```

### Agent context and memory

The `agent-context` component follows Hermes' memory split:

- `SOUL.md` holds stable identity, tone, and safety posture.
- `memories/MEMORY.md` holds compact always-on environment facts.
- `memories/USER.md` is left empty for the user profile to grow from real
  interactions.
- repeatable CVE/research procedures belong in skills, not in `MEMORY.md`.

Existing files are preserved on re-run. Use
`HERMES_AGENT_CONTEXT_FORCE=true` to regenerate the seeded context.

## Adding a new component

1. Copy `components/TEMPLATE.sh` to `components/NN-<name>.sh` (next unused
   prefix). Fill in the metadata header.
2. Paste the function bodies you want to run inside the marked block.
3. Update `run()` (and optionally `verify()`) to call them.
4. Add any new env vars to `defaults.env` and any new ports to `PORTS.md`.
5. `./install.sh --validate` lints the metadata. Done -- no orchestrator edits.

The orchestrator auto-pulls anything listed in your component's `requires:`.

## Standalone mode

Every component is also runnable on its own:

```bash
./components/20-hermes.sh
./components/40-honcho.sh
```

The bootstrap block at the top of each component sources `lib/common.sh` and
`defaults.env`, so standalone runs honor the same overrides as the orchestrator.

## Confirming the install worked

If `install.sh` returns 0 you're already 95% of the way there. To
confirm the run actually produced a working environment, the
following four checks should all succeed on a fresh install:

```bash
# 1. Orchestrator metadata is sane
./install.sh --validate

# 2. Native systemd units are active
systemctl is-active hermes-gateway hermes-dashboard ollama
# (returns 'active' on a line for each; non-zero exit means one is down)

# 3. All four native services are listening on 127.0.0.1
ss -ltn '( sport = :50000 or sport = :50010 or sport = :50040 or sport = :11434 )'
# (one row each: hermes-gateway, hermes-dashboard, honcho, ollama)

# 4. Hermes can introspect itself
hermes mcp list
# (expect: eip-mcp, semgrep, ghidra-headless-mcp all marked enabled)
```

If any of those fail, look at the most recent install run's last
component banner — the orchestrator stops on first failure and names
the failing component. Re-run with `--only <name>` after fixing the
cause.

## After install

Three things the installer can't do for you:

```bash
# 1. Interactive agent CLI logins (browser-based OAuth)
claude login
codex login

# 2. Pull at least one Ollama model so Honcho's memory pipelines work
ollama pull qwen2.5:7b                    # or any model you prefer
./install.sh --only honcho --force        # re-apply Honcho config picking up the new model

# 3. Confirm MCP servers are wired and visible to Hermes (TTY required)
hermes mcp list                           # expect: eip-mcp, semgrep, ghidra  ✓ enabled
hermes tools                              # confirms the mcp_eip_mcp_* tool schema is loaded
```

The `honcho` component auto-detects the first available Ollama model via
`ollama list`, so you don't need to set `LLM_MODEL` by hand. Set it
explicitly only if you have multiple models pulled and want to pin one:

```bash
LLM_MODEL=qwen2.5:14b ./install.sh --only honcho --force
```

Until a model is pulled, Honcho's API is healthy but its memory
pipelines will fail when actually invoked. Until `claude login` / `codex
login` have run, the corresponding CLI agents won't respond.

## Skipping and adding components

Skip parts of the default plan with `--skip NAME[,...]`:

```bash
./install.sh --skip mobile     # everything except apktool/jadx/apkeep
./install.sh --skip base-tools,recon,web,mobile,runtime-langs,re,exploit-dev   # Hermes only
```

Add `default: disabled` extras to the default plan with `--with NAME[,...]`:

```bash
./install.sh --with honcho     # full default plan + local Honcho memory backend
```

Run only specific components (and their dependencies) with `--only NAME[,...]`:

```bash
./install.sh --only honcho     # auto-pulls runtimes, ai-tools, hermes
```

Individual tools inside a component are gated by env toggles
(`INSTALL_BURP`, `INSTALL_BRAVE`, etc.); see [`defaults.env`](defaults.env).

## Operations

Hermes lives in `$HOME/.hermes` (per-user). To restart the gateway, use
the systemd unit directly -- `sudo hermes ...` won't work because `sudo`
resets `PATH` and `HOME`, and the per-user `hermes` launcher then can't
find its config:

```bash
sudo systemctl restart hermes-gateway
sudo systemctl restart hermes-dashboard
```

## Out of scope (here)

This installer intentionally does not set up Open WebUI, Hermes WebUI,
Langfuse, Multica, or the mcpo OpenAPI bridge. Their ports are reserved
in [PORTS.md](PORTS.md) so nothing else accidentally claims them.
