# eip-hermes

A clean, modular bring-up of the **Hermes** AI agent for responsible CVE
research, on Ubuntu 24.04. One bootstrap script provisions a non-root user
with passwordless sudo; one drop-in installer brings up the full local
control plane: Hermes itself (gateway + dashboard + Kanban), an Ollama LLM
runtime, and the agent CLIs you'll log into (Claude Code, Codex).

Default-plan native services bind `127.0.0.1` and live under the user's
home. The default-enabled `rdp` component installs xrdp with its stock
config, which listens on `0.0.0.0:3389` — front it with an SSH tunnel or
host firewall; don't expose `:3389` directly. Skip with `--skip rdp` for
a strict headless install. Containers and VMs spawned by labs may bind
their own ports that the installer does not centrally constrain. See
[`SECURITY.md`](SECURITY.md) for the full threat model before exposing
the host to anything beyond a trusted LAN.

## Layout

```
eip-hermes/
├── bootstrap-user.sh            # one-time: grants the current user passwordless sudo
├── AGENTS.md                    # Hermes-readable project guidance
├── CLAUDE.md                    # fuller contributor/AI-agent notes
├── installers/
│   └── hermes/                  # the main installer -- see its README for detail
│       ├── install.sh           # drop-in component orchestrator
│       ├── components/          # NN-<name>.sh files, each self-contained
│       ├── lib/                 # common.sh + security-tools.sh helpers
│       ├── defaults.env         # env-var defaults; export to override
│       ├── PORTS.md             # 50000-50999 native, exceptions documented
│       └── README.md            # quickstart, component table, contributor guide
├── SECURITY.md                  # threat model and posture for the host this installs on
├── CONTRIBUTING.md
├── LICENSE
└── README.md                    # this file
```

## Quickstart

> **First-time visitor:** read the
> ["Before you install"](installers/hermes/README.md#before-you-install)
> section in the installer README before running anything. The full
> plan needs ~120 GB disk, ~50 GB of downloads, BIOS-level KVM
> extensions, and a dedicated Ubuntu 24.04 host.

```bash
# Logged in as the user that will run hermes:

git clone https://github.com/eip-public/eip-hermes.git
cd eip-hermes

sudo ./bootstrap-user.sh           # one-time: grants passwordless sudo
./installers/hermes/install.sh     # bring up hermes
```

Detailed usage, component breakdown, port registry, and contribution flow:
see [`installers/hermes/README.md`](installers/hermes/README.md) and
[`installers/hermes/PORTS.md`](installers/hermes/PORTS.md).

## Design

- **Modular by file.** Adding a new component (e.g. a new memory backend or a
  webui front-end) means dropping one file in `installers/hermes/components/`
  with a metadata header. The orchestrator discovers it, resolves its
  dependencies, runs it. No edits to the orchestrator.
- **Standalone-runnable.** Every component can be re-run on its own
  (`./components/40-honcho.sh`) for debugging or partial reinstalls.
- **Idempotent.** Components detect installed state and skip safely. `--force`
  regenerates managed config files where applicable.
- **Loopback by default.** Native services occupy `50000-50999` on
  `127.0.0.1`; the range was chosen after a previous setup collided
  with research lab targets on common low ports. Two documented
  exceptions: Ollama (`11434`, loopback-bound) and xrdp (`3389`,
  `0.0.0.0` — see `SECURITY.md` and `PORTS.md`).
- **Two-step provisioning.** `bootstrap-user.sh` is intentionally separate
  from the main installer because granting `NOPASSWD:ALL` is security-sensitive
  and deserves an explicit, auditable, single-purpose script.

## What ships here

The default plan brings up:

- the Hermes control plane -- Hermes itself, the gateway/dashboard
  systemd units, a Kanban dispatcher, and a local Ollama LLM runtime;
- the EIP CVE skill library, cloned into Hermes' skills directory;
- an EIP-specific Hermes identity (`SOUL.md`) and compact memory seed
  that keep identity, always-on facts, and reusable procedures in the
  right Hermes layers;
- MCP server registration so the agent can call `eip-mcp`, `semgrep`,
  and `ghidra-headless-mcp` out of the box;
- a broad security toolchain -- recon, web, mobile, reverse engineering,
  and exploit-development helpers, plus the language runtimes those
  tools depend on;
- a clone of `eip-public/win11-forge` into `~/win11-forge` -- this is a
  prerequisite for building Win11 labs. The heavy KVM/libvirt/qemu deps
  and Win11/virtio ISOs are *not* installed here; run
  `~/win11-forge/install-deps.sh` yourself when you actually want to
  build a lab. Skip the clone with `--skip lab-host`.
- an XFCE4 desktop + xrdp on `0.0.0.0:3389` (the `rdp` component). Skip
  with `--skip rdp` for a strict headless install.

Opt-in extras (off by default, add with `--with NAME`): the local Honcho
memory backend (`--with honcho`, port 50040).

For the full component list, what each one installs, and how to
skip / add / `--only` them, see
[`installers/hermes/README.md`](installers/hermes/README.md).

Open WebUI, Hermes WebUI, Langfuse, Multica, and the mcpo OpenAPI
bridge are intentionally out of scope. Their ports are already reserved
in [`installers/hermes/PORTS.md`](installers/hermes/PORTS.md).

## License

[MIT](LICENSE).
