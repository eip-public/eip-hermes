#!/usr/bin/env bash
# eip-hermes-component:
#   name: re
#   description: Reverse engineering -- Ghidra, BinExport, BinDiff, winbindex, ghidra-headless-mcp
#   default: enabled
#   ports:
#   requires: base-tools,runtime-langs

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi
# shellcheck disable=SC1091
source "$INSTALLER_DIR/lib/security-tools.sh"

install_ghidra() {
  local dir="/opt/ghidra_${GHIDRA_VERSION}_PUBLIC"
  if [[ ! -x "$dir/ghidraRun" ]]; then
    log "Installing Ghidra ${GHIDRA_VERSION}"
    local tmp
    tmp="$(mktemp -d)"
    download_to \
      "$tmp/ghidra.zip" \
      "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_BUILD}.zip"
    unzip -q "$tmp/ghidra.zip" -d /opt
    rm -rf "$tmp"
  else
    log "Ghidra ${GHIDRA_VERSION} already installed"
  fi

  ln -sfn "$dir" /opt/ghidra
  ln -sf /opt/ghidra/ghidraRun "$BIN/ghidraRun"
  ln -sf /opt/ghidra/support/analyzeHeadless "$BIN/analyzeHeadless"

  local props="$dir/support/launch.properties"
  if [[ -f "$props" ]]; then
    sed -i 's/^MAXMEM=.*/MAXMEM=8G/' "$props" 2>/dev/null || true
  fi

  if [[ "$ARCH" == "arm64" ]]; then
    local arm_dir=/opt/ghidra/Ghidra/Features/Decompiler/os/linux_arm_64
    if [[ ! -x "$arm_dir/decompile" || ! -x "$arm_dir/sleigh" ]]; then
      log "Building arm64 Ghidra decompiler binaries"
      install -d -m 0755 "$arm_dir"
      (
        cd /opt/ghidra/Ghidra/Features/Decompiler
        GRADLE_USER_HOME=/tmp/ghidra-gradle-home gradle decompileLinux_arm_64Executable sleighLinux_arm_64Executable
      ) || warn "arm64 Ghidra decompiler build failed"
      if [[ -x /opt/ghidra/Ghidra/Features/Decompiler/build/os/linux_arm_64/decompile ]]; then
        install -m 0755 /opt/ghidra/Ghidra/Features/Decompiler/build/os/linux_arm_64/decompile "$arm_dir/decompile"
        install -m 0755 /opt/ghidra/Ghidra/Features/Decompiler/build/os/linux_arm_64/sleigh "$arm_dir/sleigh"
      fi
    fi
  fi
}

install_binexport() {
  local staging_dir=/opt/ghidra-extensions
  local extension_dir=/opt/ghidra/Ghidra/Extensions
  local installed_props="$extension_dir/BinExport/extension.properties"
  local zip_path=""

  install -m 0755 -d "$staging_dir" "$extension_dir"
  if [[ -s "$installed_props" ]]; then
    log "BinExport extension already installed"
    return 0
  fi

  zip_path="$(find "$staging_dir" -maxdepth 1 -type f -iname '*BinExport*.zip' -print -quit)"

  if [[ -n "${BINEXPORT_ZIP:-}" && -s "$BINEXPORT_ZIP" ]]; then
    log "Installing local BinExport extension from BINEXPORT_ZIP"
    cp "$BINEXPORT_ZIP" "$staging_dir/"
    zip_path="$staging_dir/$(basename "$BINEXPORT_ZIP")"
  fi

  if [[ -z "$zip_path" ]]; then
    log "Downloading upstream BinExport extension"
    local tmp
    tmp="$(mktemp -d)"
    if download_to \
      "$tmp/binexport.zip" \
      "$BINEXPORT_URL"; then
      zip_path="$staging_dir/BinExport_Ghidra-Java.zip"
      cp "$tmp/binexport.zip" "$zip_path"
    else
      warn "BinExport download failed"
    fi
    rm -rf "$tmp"
  fi

  if [[ -n "$zip_path" && -s "$zip_path" ]]; then
    log "Installing BinExport extension into Ghidra"
    local tmp_extract nested_zip
    tmp_extract="$(mktemp -d)"
    if unzip -q -o "$zip_path" -d "$tmp_extract"; then
      if [[ -d "$tmp_extract/BinExport" ]]; then
        cp -a "$tmp_extract/BinExport" "$extension_dir/"
      else
        nested_zip="$(find "$tmp_extract" -maxdepth 1 -type f -iname '*BinExport*.zip' -print -quit)"
        if [[ -n "$nested_zip" ]]; then
          unzip -q -o "$nested_zip" -d "$extension_dir" || warn "nested BinExport extension install failed"
        else
          warn "BinExport archive did not contain BinExport/ or a nested BinExport zip"
        fi
      fi
    else
      warn "BinExport extension install failed"
    fi
    rm -rf "$tmp_extract"
  fi
}

install_bindiff() {
  if [[ "$ARCH" != "amd64" ]]; then
    log "Skipping BinDiff (amd64 only)"
    return 0
  fi
  if [[ -x /opt/bindiff/bin/bindiff || -x /usr/bin/bindiff || -x /usr/local/bin/bindiff ]]; then
    log "BinDiff already installed"
    return 0
  fi

  log "Installing BinDiff ${BINDIFF_VERSION}"
  local tmp deb
  tmp="$(mktemp -d)"
  deb="bindiff_${BINDIFF_VERSION}_amd64.deb"
  download_to \
    "$tmp/$deb" \
    "https://github.com/google/bindiff/releases/download/v${BINDIFF_VERSION}/${deb}"
  chmod 0755 "$tmp"
  apt_install "$tmp/$deb" || warn "BinDiff install failed"
  rm -rf "$tmp"
}

install_winbindex() {
  log "Installing winbindex helper"
  cat > "$BIN/winbindex" <<'PYEOF'
#!/usr/bin/env python3
"""Small Winbindex client for finding/downloading Microsoft PE files.

Uses Winbindex metadata from m417z/winbindex and Microsoft public symbol-server
URLs. It does not redistribute Microsoft binaries.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import sys
import urllib.parse
import urllib.request

VERSION = "0.1"
BASE = "https://raw.githubusercontent.com/m417z/winbindex/gh-pages/data/by_filename_compressed"
MACHINE_ARCH = {332: "x86", 34404: "x64", 43620: "arm64"}
ARCH_MACHINE = {
    "x86": {332},
    "i386": {332},
    "x64": {34404},
    "amd64": {34404},
    "arm64": {43620},
    "aarch64": {43620},
}


def symbol_url(name: str, file_info: dict) -> str | None:
    timestamp = file_info.get("timestamp")
    image_size = file_info.get("virtualSize")
    if timestamp is None or not image_size:
        return None
    file_id = f"{int(timestamp):08X}{int(image_size):x}"
    return f"https://msdl.microsoft.com/download/symbols/{name}/{file_id}/{name}"


def load_metadata(name: str) -> dict:
    quoted = urllib.parse.quote(name.lower(), safe="._-")
    url = f"{BASE}/{quoted}.json.gz"
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return json.loads(gzip.decompress(response.read()).decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            raise SystemExit(f"No Winbindex metadata found for {name!r}") from exc
        raise


def iter_contexts(record: dict):
    versions = record.get("windowsVersions") or {}
    for release, kb_map in versions.items():
        if not isinstance(kb_map, dict):
            continue
        for kb, kb_data in kb_map.items():
            update_info = kb_data.get("updateInfo") or {}
            assemblies = kb_data.get("assemblies") or {}
            if not assemblies:
                yield {
                    "release": release,
                    "kb": kb,
                    "assembly_version": "",
                    "assembly_arch": "",
                    "update_url": update_info.get("updateUrl", ""),
                }
                continue
            for assembly in assemblies.values():
                identity = (assembly.get("assemblyIdentity") or {}) if isinstance(assembly, dict) else {}
                yield {
                    "release": release,
                    "kb": kb,
                    "assembly_version": identity.get("version", ""),
                    "assembly_arch": identity.get("processorArchitecture", ""),
                    "update_url": update_info.get("updateUrl", ""),
                }


def release_matches(release: str, windows: str | None, wanted_release: str | None) -> bool:
    rel = release.lower()
    if wanted_release and rel != wanted_release.lower():
        return False
    if not windows:
        return True
    windows = windows.lower().replace("windows", "").strip()
    if windows == "11":
        return rel.startswith("11-")
    if windows == "10":
        return not rel.startswith("11-")
    return windows in rel


def version_key(version: object) -> tuple[int, ...]:
    head = str(version or "").split()[0]
    parts = []
    for piece in head.split("."):
        try:
            parts.append(int(piece))
        except ValueError:
            break
    return tuple(parts)


def collect(args: argparse.Namespace) -> list[dict]:
    metadata = load_metadata(args.file)
    rows = []
    allowed_machines = ARCH_MACHINE.get(args.arch.lower()) if args.arch else None
    for sha256, record in metadata.items():
        file_info = record.get("fileInfo") or {}
        if allowed_machines and file_info.get("machineType") not in allowed_machines:
            continue
        url = symbol_url(args.file, file_info)
        contexts = [
            ctx for ctx in iter_contexts(record)
            if release_matches(ctx["release"], args.windows, args.release)
            and (not args.kb or ctx["kb"].lower() == args.kb.lower().removeprefix("kb"))
        ]
        if not contexts:
            continue
        haystack = " ".join(
            [str(file_info.get("version", "")), sha256]
            + [ctx.get("assembly_version", "") for ctx in contexts]
        ).lower()
        if args.build and args.build.lower() not in haystack:
            continue
        rows.append({
            "sha256": sha256,
            "version": file_info.get("version", ""),
            "description": file_info.get("description", ""),
            "arch": MACHINE_ARCH.get(file_info.get("machineType"), str(file_info.get("machineType", ""))),
            "size": file_info.get("size"),
            "timestamp": file_info.get("timestamp"),
            "url": url,
            "contexts": contexts,
        })
    rows.sort(key=lambda row: version_key(row.get("version")), reverse=True)
    return rows


def format_kb(kb: str) -> str:
    kb = str(kb)
    return kb if kb.lower().startswith("kb") else f"KB{kb}"


def print_rows(rows: list[dict], limit: int) -> None:
    for row in rows[:limit]:
        releases = ", ".join(
            f"{ctx['release']}/{format_kb(ctx['kb'])}" for ctx in row["contexts"][:6]
        )
        if len(row["contexts"]) > 6:
            releases += f", +{len(row['contexts']) - 6} more"
        print(f"sha256: {row['sha256']}")
        print(f"version: {row['version']}")
        print(f"arch: {row['arch']}")
        print(f"size: {row['size']}")
        print(f"releases: {releases}")
        print(f"url: {row['url'] or '(no direct symbol-server URL in metadata)'}")
        print()


def download_rows(file_name: str, rows: list[dict], output: str, limit: int) -> None:
    os.makedirs(output, exist_ok=True)
    for row in rows[:limit]:
        if not row["url"]:
            print(f"skip {row['sha256']}: no direct URL", file=sys.stderr)
            continue
        version = str(row.get("version") or row["sha256"][:12]).split()[0]
        dest_dir = os.path.join(output, f"{version}-{row['arch']}")
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, file_name)
        print(f"download: {row['url']} -> {dest}")
        urllib.request.urlretrieve(row["url"], dest)


def main() -> int:
    parser = argparse.ArgumentParser(description="Find/download Windows PE files using Winbindex metadata")
    parser.add_argument("file", help="PE file name, e.g. ntoskrnl.exe or kernel32.dll")
    parser.add_argument("--windows", help="Windows major version filter, e.g. 10 or 11")
    parser.add_argument("--release", help="Winbindex release key, e.g. 22H2 or 11-24H2")
    parser.add_argument("--arch", help="Architecture filter: x86, x64/amd64, arm64")
    parser.add_argument("--build", help="Version/build substring, e.g. 26100.4061")
    parser.add_argument("--kb", help="KB filter, accepts KB5060842 or 5060842")
    parser.add_argument("--limit", type=int, default=20, help="Maximum rows to list/download")
    parser.add_argument("--download", action="store_true", help="Download matching PE files")
    parser.add_argument("--output", default=".", help="Output directory for --download")
    parser.add_argument("--json", action="store_true", help="Emit JSON rows")
    parser.add_argument("--version", action="version", version=f"winbindex {VERSION}")
    args = parser.parse_args()

    rows = collect(args)
    if args.json:
        print(json.dumps(rows[:args.limit], indent=2))
    else:
        print_rows(rows, args.limit)
    if args.download:
        download_rows(args.file, rows, args.output, args.limit)
    return 0 if rows else 1


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
  chmod 0755 "$BIN/winbindex"
}

install_ghidra_mcp() {
  [[ "$INSTALL_GHIDRA_MCP" == "1" ]] || return 0
  local dir=/opt/ghidra-headless-mcp
  if [[ ! -d "$dir/.git" ]]; then
    log "Installing ghidra-headless-mcp"
    rm -rf "$dir"
    retry 3 10 git clone --depth 1 https://github.com/mrphrazer/ghidra-headless-mcp.git "$dir"
  else
    log "ghidra-headless-mcp already cloned"
  fi

  if [[ ! -x "$dir/.venv/bin/python3" ]] || ! "$dir/.venv/bin/python3" -c 'import pyghidra' >/dev/null 2>&1; then
    python3 -m venv "$dir/.venv"
    # --no-cache-dir: 80-re.sh runs as root via sudo -E, which preserves
    # HOME=/home/<user>, so pip would try to read/write the user-owned
    # ~/.cache/pip and emit a permissions warning. The venv pip has no
    # need for an inter-run cache.
    "$dir/.venv/bin/pip" install --no-cache-dir --retries 5 "pyghidra>=3.0.2"
    "$dir/.venv/bin/pip" install --no-cache-dir --quiet "$dir/."
  fi

  cat > "$BIN/ghidra-headless-mcp" <<EOF
#!/usr/bin/env bash
export GHIDRA_INSTALL_DIR="\${GHIDRA_INSTALL_DIR:-/opt/ghidra}"
exec "$dir/.venv/bin/python3" "$dir/ghidra_headless_mcp.py" "\$@"
EOF
  chmod 0755 "$BIN/ghidra-headless-mcp"

  "$BIN/ghidra-headless-mcp" --help >/dev/null

  local server_py="$dir/ghidra_headless_mcp/server.py"
  if [[ -f "$server_py" ]] && grep -q 'return {"type": "array"}' "$server_py"; then
    python3 - "$server_py" <<'PYEOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '    if param_name in {"args", "script_args", "values"}:\n        return {"type": "array"}\n'
new = '    if param_name in {"args", "script_args", "values"}:\n        return {"type": "array", "items": {}}\n'
if old in text:
    path.write_text(text.replace(old, new, 1))
PYEOF
  fi
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 80-re.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/80-re.sh"
    return $?
  fi
  detect_arch
  setup_context

  install_ghidra
  install_binexport
  install_bindiff
  install_winbindex
  install_ghidra_mcp
}

verify() {
  if [ -x /opt/ghidra/ghidraRun ]; then success "ghidra: /opt/ghidra (${GHIDRA_VERSION})"; else warn "ghidra not installed"; fi
  if need_cmd winbindex; then success "winbindex: $(command -v winbindex)"; else warn "winbindex not on PATH"; fi
  if [[ "$INSTALL_GHIDRA_MCP" == "1" ]] && need_cmd ghidra-headless-mcp; then
    success "ghidra-headless-mcp: $(command -v ghidra-headless-mcp)"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
