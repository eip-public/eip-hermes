# Security model

eip-hermes is a developer/research installer. The default plan
provisions an autonomous AI agent (Hermes + Claude Code/Codex) with
broad host access. **This setup is not intended for public-facing
hosts.** Read this before exposing the machine to anything beyond a
trusted LAN.

## What the install grants

- `bootstrap-user.sh` writes a `/etc/sudoers.d/eip-hermes-<user>`
  fragment granting `NOPASSWD:ALL` to the invoking user. Every later
  step the installer (and the agents it installs) runs as that user
  inherits unrestricted `sudo`. This is required for the installer to
  function; it is also the largest blast radius in the design.
- The Hermes/Claude/Codex agents run as that same user. They are not
  sandboxed, not network-isolated, and not rate-limited. They can read
  any file the user can read, write any file the user can write, and
  invoke any program the user can invoke — including `sudo`.
- **Prompt instructions are not a security boundary.** "Don't do X" in
  a skill or system message is guidance, not enforcement.

## Network exposure

- Native services (gateway, dashboard, Honcho, Ollama) bind
  `127.0.0.1` on 50000–50999 (Ollama 11434). Not reachable from the
  network without explicit forwarding.
- The opt-in `rdp` component installs xrdp with its stock config,
  which listens on `0.0.0.0:3389`. The recommended posture is to
  firewall `:3389` at the host and reach it over an SSH tunnel.
- The opt-in `lab-host` component does not start services on the host,
  but labs spawned later (Docker containers, KVM/libvirt domains,
  VMware Workstation VMs) commonly bind their own ports. The installer
  does not centrally constrain those bindings.

## Recommended posture for any internet-adjacent host

- Drop or default-deny all inbound except `:22` at the host firewall.
- SSH-tunnel any UI you actually need (`:3389` for RDP, `:50010` for
  the dashboard, etc.).
- Treat the agent's host as if it were a privileged developer
  workstation. Don't put production data on it. Don't share it.
- The agent can disable the firewall. If you rely on iptables/ufw
  rules for isolation, you also need to accept that an agent with
  passwordless sudo can remove them. Network-level segmentation
  (separate host, separate VLAN) is the only durable boundary.

## Reporting an issue

There is no private vulnerability-disclosure channel set up for this
project today. If you find a bug or footgun worth flagging, open a
GitHub issue. Please don't include a working host or a path to a
working host in a public issue.
