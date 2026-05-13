# Contributing to eip-hermes

Thanks for the interest. This is a focused repo: a modular installer for
the Hermes AI agent platform on Ubuntu 24.04. The architecture is small
and deliberate, so most contributions fit one of three shapes.

## Adding a new component

The whole point of the orchestrator is that this is the easy path:

1. Copy `installers/hermes/components/TEMPLATE.sh` to
   `components/NN-<name>.sh` (next unused numeric prefix).
2. Fill in the metadata header -- `name`, `description`, `default`,
   `ports`, `requires`. Validate with
   `./installers/hermes/install.sh --validate`.
3. Write the install body in the marked block.
4. Define `run()` and (optionally) `verify()`. If your component needs
   root, follow the inline-re-exec pattern used in `50-base-tools.sh`
   and friends.
5. Add any new env vars to `defaults.env`. Any new listening ports go
   into `PORTS.md` (the registry, not folklore).
6. Update `installers/hermes/README.md`'s component table.

`./installers/hermes/install.sh --list` should now show your component.
`--dry-run` should include it in the plan if it's `default: enabled`,
or appear under `--with <name>` if it's `default: disabled`.

## Fixing a bug in installer or orchestration code

- All code in this repo is fair game for direct modification --
  orchestrator, lib, component scaffolds, and the function bodies
  inside components.
- Follow the existing pattern: small, well-commented changes; explain
  the *why* (especially around root re-exec, helper-name overrides,
  and HOME/SUDO_USER semantics).

## Style

- `set -Eeuo pipefail` at the top of every shell script.
- Use the helpers in `lib/common.sh` (`log`, `success`, `warn`, `fail`,
  `need_cmd`, `sudo_cmd`) wherever possible. Don't re-define them
  unless your component intentionally overrides the helper style
  (as `lib/security-tools.sh` does with its `==>` prefix); call that
  out at the top of the file.
- Don't add comments that just describe what the code does; add
  comments only where the *why* is non-obvious (a hidden constraint,
  a workaround for an upstream behavior, a deliberate deviation).
- Don't introduce new dependencies on third-party install scripts
  without flagging them in the PR description.

## Local checks before opening a PR

Run these locally; they're what a reviewer will run:

```bash
./installers/hermes/install.sh --validate     # component metadata lint
./installers/hermes/install.sh --dry-run      # default plan resolves cleanly
shellcheck -x --exclude=SC1091,SC2034,SC2317,SC2068,SC2015,SC2024 \
  bootstrap-user.sh \
  installers/hermes/install.sh \
  installers/hermes/lib/*.sh \
  installers/hermes/components/*.sh
```
