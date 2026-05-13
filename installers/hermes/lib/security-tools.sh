#!/usr/bin/env bash
# Shared globals + helpers for security-tools components (50-* through 85-*).
#
# Extracted byte-identical from the upstream security-skills/scripts/install-
# tools-ubuntu2404.sh (lines 32-269 minus require_root/check_platform -- those
# are not needed because each component handles its own root re-exec and
# preflight has already verified Ubuntu 24.04).
#
# Sourced AFTER lib/common.sh and defaults.env in each component's bootstrap
# block. The extracted upstream blocks call die() rather than fail();
# common.sh aliases die() to fail() so the bodies work unchanged.

# ----------------------- Toggle normalization -------------------------------
# defaults.env stores boolean toggles as true/false. The upstream security
# script tests them as "1"/"0". Translate so the extracted function bodies
# remain byte-identical without a defaults.env churn. Unrecognized values
# warn and fall through to the default (install).
case "${INSTALL_DOCKER:-1}" in
  true|TRUE|True|1|yes|YES|Yes|on|ON|On)    INSTALL_DOCKER=1 ;;
  false|FALSE|False|0|no|NO|No|off|OFF|Off) INSTALL_DOCKER=0 ;;
  *) printf 'WARN: INSTALL_DOCKER=%q not recognised; treating as 1 (install). Use true/false or 1/0.\n' "$INSTALL_DOCKER" >&2
     INSTALL_DOCKER=1 ;;
esac
# Toggles unique to security-tools (no defaults.env conflict).
INSTALL_BRAVE="${INSTALL_BRAVE:-1}"
INSTALL_GH="${INSTALL_GH:-1}"
INSTALL_METASPLOIT="${INSTALL_METASPLOIT:-1}"
INSTALL_BURP="${INSTALL_BURP:-1}"
INSTALL_GHIDRA_MCP="${INSTALL_GHIDRA_MCP:-1}"
INSTALL_WINE="${INSTALL_WINE:-1}"
APPLY_USER_PERMISSIONS="${APPLY_USER_PERMISSIONS:-1}"
ALLOW_UNSUPPORTED="${ALLOW_UNSUPPORTED:-0}"

# ----------------------- Pinned versions -----------------------------------
NODE_MAJOR="${NODE_MAJOR:-22}"
LAZYDOCKER_VERSION="${LAZYDOCKER_VERSION:-0.25.0}"
CTOP_VERSION="${CTOP_VERSION:-0.7.7}"
FFUF_VERSION="${FFUF_VERSION:-2.1.0}"
NUCLEI_VERSION="${NUCLEI_VERSION:-3.7.1}"
APKTOOL_VERSION="${APKTOOL_VERSION:-3.0.1}"
JADX_VERSION="${JADX_VERSION:-1.5.5}"
GO_VERSION="${GO_VERSION:-1.26.2}"
GRADLE_VERSION="${GRADLE_VERSION:-9.4.1}"
GHIDRA_VERSION="${GHIDRA_VERSION:-12.0.4}"
GHIDRA_BUILD="${GHIDRA_BUILD:-20260303}"
APKEEP_VERSION="${APKEEP_VERSION:-0.18.0}"
BINDIFF_VERSION="${BINDIFF_VERSION:-8}"
YSOSERIAL_VERSION="${YSOSERIAL_VERSION:-0.0.6}"
BURP_VERSION="${BURP_VERSION:-2026.3.2}"
BINEXPORT_URL="${BINEXPORT_URL:-https://github.com/google/binexport/releases/download/v12-20240417-ghidra_11.0.3/BinExport_Ghidra-Java.zip}"

# ----------------------- curl options & package sets -----------------------
CURL_OPTS=(
  --http1.1
  --retry 5
  --retry-delay 5
  --retry-all-errors
  --connect-timeout 15
  --max-time 1800
  --speed-limit 1
  --speed-time 30
)

APT_BASE_PACKAGES=(
  ca-certificates curl gnupg wget
  ripgrep jq unzip zip xz-utils tar
  git make gcc clang cmake shellcheck
  netcat-openbsd lsof file tcpdump openssl net-tools
  build-essential pkg-config
  cabextract wimtools
  python3 python3-pip python3-venv python3-pefile python3-pwntools pipx
  openjdk-21-jdk openjdk-17-jdk maven
  php-cli php-curl php-mbstring php-xml php-zip composer
  ruby ruby-dev
  mariadb-client postgresql-client sqlite3
  radare2 nmap hashcat locate sqlmap
  gdb gdb-multiarch lldb python3-tk
  subversion crash
  qemu-system-arm qemu-system-x86 qemu-utils qemu-efi-aarch64
  xorriso p7zip-full pigz parted e2fsprogs util-linux perl
  aapt apksigner zipalign android-tools-adb
)

PIPX_PACKAGES=(
  semgrep
  eip-mcp
  mitmproxy
  ropper
  ropgadget
  frida-tools
  uv
  mcpo
)

NPM_GLOBAL_PACKAGES=(
  @openai/codex
)

# ----------------------- Helpers (extend common.sh) ------------------------
# log/warn/fail/die already defined in common.sh.

retry() {
  local attempts="$1" delay="$2"
  shift 2
  local i rc=0
  for ((i = 1; i <= attempts; i++)); do
    "$@" && return 0
    rc=$?
    if ((i < attempts)); then
      warn "attempt $i/$attempts failed (rc=$rc): $*"
      sleep "$delay"
    fi
  done
  return "$rc"
}

download_to() {
  local dest="${1:?dest required}" url="${2:?url required}"
  local partial="${dest}.partial"
  curl -fsSL "${CURL_OPTS[@]}" "$url" -o "$partial"
  mv "$partial" "$dest"
}

download_stdout() {
  local url="${1:?url required}"
  curl -fsSL "${CURL_OPTS[@]}" "$url"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

detect_current_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    id "$SUDO_USER" >/dev/null 2>&1 || die "sudo-invoking user '$SUDO_USER' does not exist"
    printf '%s\n' "$SUDO_USER"
    return 0
  fi
  return 1
}

apt_install() {
  if (($# == 0)); then
    return 0
  fi
  apt-get install -y "$@"
}

# ----------------------- Architecture detection ----------------------------
detect_arch() {
  ARCH="$(dpkg --print-architecture)"
  case "$ARCH" in
    amd64)
      GOARCH=amd64
      LAZYDOCKER_TGZ_ARCH=x86_64
      CTOP_BIN_ARCH=amd64
      APKEEP_ARCH=x86_64-unknown-linux-gnu
      BURP_DL_TYPE=Linux
      BURP_INSTALLER_NAME="burpsuite_community_linux_v${BURP_VERSION//./_}.sh"
      ;;
    arm64)
      GOARCH=arm64
      LAZYDOCKER_TGZ_ARCH=arm64
      CTOP_BIN_ARCH=arm64
      APKEEP_ARCH=aarch64-unknown-linux-gnu
      BURP_DL_TYPE=LinuxArm64
      BURP_INSTALLER_NAME="burpsuite_community_linux_arm64_v${BURP_VERSION//./_}.sh"
      ;;
    *)
      die "unsupported architecture: $ARCH"
      ;;
  esac
}

# ----------------------- Context setup -------------------------------------
setup_context() {
  CACHE_DIR="${CACHE_DIR:-/var/cache/eip-tools}"
  BIN=/usr/local/bin
  OPT=/opt
  CURRENT_USER=""
  USER_PERMISSION_CHANGES=()

  if [[ "$APPLY_USER_PERMISSIONS" == "1" ]]; then
    if CURRENT_USER="$(detect_current_user)"; then
      log "Current user for tool permissions: $CURRENT_USER"
    else
      warn "no sudo-invoking user detected; skipping user permission grants"
    fi
  fi

  mkdir -p "$BIN" "$OPT" "$CACHE_DIR"

  export DEBIAN_FRONTEND=noninteractive
  git config --system http.version HTTP/1.1 || true
}

grant_current_user_group() {
  local group="${1:?group required}"

  [[ "$APPLY_USER_PERMISSIONS" == "1" ]] || return 0
  [[ -n "${CURRENT_USER:-}" ]] || return 0

  if ! getent group "$group" >/dev/null 2>&1; then
    warn "group '$group' does not exist; skipping permission grant for $CURRENT_USER"
    return 0
  fi
  if id -nG "$CURRENT_USER" | tr ' ' '\n' | grep -Fxq "$group"; then
    log "$CURRENT_USER already in $group group"
    return 0
  fi

  log "Adding $CURRENT_USER to $group group"
  usermod -aG "$group" "$CURRENT_USER"
  USER_PERMISSION_CHANGES+=("$group")
}

# ----------------------- Root re-exec pattern (inlined per component) ------
# A previous version of this file defined a `require_root_or_reexec` helper
# that did `sudo -E bash "$file"; exit $?`. That `exit` killed the parent
# orchestrator (because components are sourced into the orchestrator's
# shell, not run as subprocesses). Each component's run() now inlines the
# pattern at its top:
#
#   run() {
#     if [ "$(id -u)" -ne 0 ]; then
#       sudo -E bash "$COMPONENT_DIR/<this-file>.sh"
#       return $?
#     fi
#     detect_arch
#     setup_context
#     install_X
#     ...
#   }
#
# `return $?` exits run() with the subprocess's status; the orchestrator's
# `set -e` then propagates a failure correctly without killing itself.
# Inlining (rather than wrapping in a helper) is intentional -- `return` from
# inside a helper would only return from the helper, not from run().
