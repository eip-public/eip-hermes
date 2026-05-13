# Port registry -- `installers/hermes`

All EIP/Hermes native services occupy ports in **50000–50999**, bound to
**127.0.0.1**. Low ports are reserved for labs and target services we spin up
during research. Putting native services on common low ports has bitten this
project before -- services collided with lab targets in subtle ways. The 50k
range keeps native infrastructure cleanly out of the way.

## In scope here

| Port  | Service              | Component       | Override env          |
|-------|----------------------|-----------------|-----------------------|
| 50000 | Hermes API gateway   | `control-plane` | `HERMES_API_PORT`     |
| 50010 | Hermes dashboard     | `control-plane` | `HERMES_DASHBOARD_PORT` |
| 50040 | Honcho API           | `honcho`        | `HONCHO_API_PORT`     |

## Documented exceptions

| Port  | Service              | Component       | Override env          | Bind         |
|-------|----------------------|-----------------|-----------------------|--------------|
| 11434 | Ollama API           | `ai-tools`      | `OLLAMA_PORT`         | 127.0.0.1    |
| 3389  | xrdp (RDP)           | `rdp`           | (xrdp config)         | 0.0.0.0      |

**Ollama** is a third-party LLM runtime with a well-known port (`11434`)
that every Ollama-aware tool defaults to. Remapping it to a 50k slot would
cost compatibility with no real safety gain: Ollama binds `127.0.0.1` only
(we enforce this via a systemd drop-in in the `ai-tools` component), and
`11434` is unlikely to collide with research lab targets.

**xrdp** uses `3389/tcp`, the RDP standard. The `rdp` component is opt-in
(`./install.sh --with rdp`) and ships xrdp's default config, which binds
`0.0.0.0`. Don't expose `:3389` directly to the public internet -- front
with an SSH tunnel or restrict via firewall. The component itself does
not enforce a loopback bind.

## Reserved (other installers -- do not reuse)

These slots are claimed by components that live elsewhere or arrive in later
phases. Don't repurpose them.

| Port  | Reserved for                  |
|-------|-------------------------------|
| 50020 | Langfuse web                  |
| 50030 | mcpo OpenAPI bridge           |
| 50050 | Multica backend               |
| 50060 | Multica frontend              |
| 50070 | Open WebUI                    |
| 50080 | Hermes WebUI                  |
| 50090 | Langfuse MinIO API            |
| 50091 | Langfuse MinIO console        |

## Adding a new component

1. Pick the next free 50k slot.
2. Declare it in your component's metadata header: `# ports: 50100:my-service`.
3. Add a row to the **In scope** table above.
4. Bind to `127.0.0.1`. Public exposure is opt-in, never default.
