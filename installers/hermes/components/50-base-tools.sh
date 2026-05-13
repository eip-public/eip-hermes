#!/usr/bin/env bash
# eip-hermes-component:
#   name: base-tools
#   description: Base apt packages, external repos, npm/pipx tools, docker TUIs (lazydocker, ctop)
#   default: enabled
#   ports:
#   requires: runtimes

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

install_apt_prereqs() {
  log "Preparing apt"
  apt-get update -qq
  apt_install software-properties-common ca-certificates curl gnupg
  add-apt-repository -y universe >/dev/null 2>&1 || true
}

install_nodesource_repo() {
  if have_cmd node && node --version | grep -qE "^v(${NODE_MAJOR}|24|26)\."; then
    log "Node.js $(node --version) already installed"
    return 0
  fi

  log "Adding NodeSource Node.js ${NODE_MAJOR}.x repo"
  local tmp
  tmp="$(mktemp -d)"
  download_to "$tmp/nodesource.sh" "https://deb.nodesource.com/setup_${NODE_MAJOR}.x"
  bash "$tmp/nodesource.sh"
  rm -rf "$tmp"
}

install_keyring_file() {
  local url="${1:?url required}" dest="${2:?dest required}"
  install -m 0755 -d "$(dirname "$dest")"
  if [[ ! -s "$dest" ]]; then
    download_to "$dest" "$url"
    chmod a+r "$dest"
  fi
}

install_dearmored_keyring() {
  local url="${1:?url required}" dest="${2:?dest required}"
  install -m 0755 -d "$(dirname "$dest")"
  if [[ ! -s "$dest" ]]; then
    local tmp
    tmp="$(mktemp)"
    download_stdout "$url" | gpg --dearmor > "$tmp"
    install -m 0644 "$tmp" "$dest"
    rm -f "$tmp"
  fi
}

configure_external_apt_repos() {
  local codename
  # shellcheck disable=SC1091
  codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME}")"

  install_nodesource_repo

  if [[ "$INSTALL_DOCKER" == "1" ]]; then
    log "Adding Docker apt repo"
    install_keyring_file \
      https://download.docker.com/linux/ubuntu/gpg \
      /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$ARCH" "$codename" > /etc/apt/sources.list.d/docker.list
  fi

  if [[ "$INSTALL_BRAVE" == "1" ]]; then
    log "Adding Brave apt repo"
    install_keyring_file \
      https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
      /etc/apt/keyrings/brave-browser-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main\n' \
      "$ARCH" > /etc/apt/sources.list.d/brave-browser-release.list
  fi

  if [[ "$INSTALL_GH" == "1" ]]; then
    log "Adding GitHub CLI apt repo"
    install_keyring_file \
      https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$ARCH" > /etc/apt/sources.list.d/github-cli.list
  fi

  if [[ "$INSTALL_METASPLOIT" == "1" ]]; then
    log "Adding Metasploit apt repo"
    install_dearmored_keyring \
      https://apt.metasploit.com/metasploit-framework.gpg.key \
      /etc/apt/keyrings/metasploit-framework.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/metasploit-framework.gpg] http://apt.metasploit.com lucid main\n' \
      > /etc/apt/sources.list.d/metasploit-framework.list
  fi
}

install_apt_tools() {
  local packages=("${APT_BASE_PACKAGES[@]}" nodejs)

  if [[ "$INSTALL_WINE" == "1" ]]; then
    packages+=(wine winetricks)
  fi
  if [[ "$INSTALL_DOCKER" == "1" ]]; then
    packages+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  fi
  if [[ "$INSTALL_BRAVE" == "1" ]]; then
    packages+=(brave-browser)
  fi
  if [[ "$INSTALL_GH" == "1" ]]; then
    packages+=(gh)
  fi
  if [[ "$INSTALL_METASPLOIT" == "1" ]]; then
    packages+=(metasploit-framework)
  fi

  log "Installing apt tools"
  apt-get update -qq
  apt_install "${packages[@]}"

  if [[ "$INSTALL_DOCKER" == "1" ]]; then
    log "Enabling Docker"
    systemctl enable --now docker >/dev/null 2>&1 || warn "docker service did not start"
  fi
}

grant_current_user_permissions() {
  [[ "$APPLY_USER_PERMISSIONS" == "1" ]] || return 0
  [[ -n "${CURRENT_USER:-}" ]] || return 0

  [[ "$INSTALL_DOCKER" == "1" ]] && grant_current_user_group docker
  grant_current_user_group kvm
  grant_current_user_group plugdev
}

install_npm_tools() {
  if ((${#NPM_GLOBAL_PACKAGES[@]} == 0)); then
    return 0
  fi
  log "Installing npm globals"
  local pkg
  for pkg in "${NPM_GLOBAL_PACKAGES[@]}"; do
    if npm list -g --depth=0 "$pkg" >/dev/null 2>&1; then
      log "$pkg already installed"
    else
      retry 3 10 npm install -g "$pkg"
    fi
  done
}

install_pipx_tools() {
  log "Installing system-wide pipx tools"
  export PIPX_HOME=/opt/pipx
  export PIPX_BIN_DIR=/usr/local/bin
  mkdir -p "$PIPX_HOME" "$PIPX_BIN_DIR"

  local pkg
  for pkg in "${PIPX_PACKAGES[@]}"; do
    if PIPX_HOME=$PIPX_HOME PIPX_BIN_DIR=$PIPX_BIN_DIR pipx list --short 2>/dev/null | grep -q "^${pkg} "; then
      log "$pkg already installed, upgrading"
      PIPX_HOME=$PIPX_HOME PIPX_BIN_DIR=$PIPX_BIN_DIR pipx upgrade "$pkg" >/dev/null || true
    else
      PIPX_HOME=$PIPX_HOME PIPX_BIN_DIR=$PIPX_BIN_DIR retry 3 10 pipx install "$pkg"
    fi
  done
}

install_docker_tuis() {
  [[ "$INSTALL_DOCKER" == "1" ]] || return 0

  if ! have_cmd lazydocker; then
    log "Installing lazydocker ${LAZYDOCKER_VERSION}"
    local tmp
    tmp="$(mktemp -d)"
    download_to \
      "$tmp/lazydocker.tgz" \
      "https://github.com/jesseduffield/lazydocker/releases/download/v${LAZYDOCKER_VERSION}/lazydocker_${LAZYDOCKER_VERSION}_Linux_${LAZYDOCKER_TGZ_ARCH}.tar.gz"
    tar xzf "$tmp/lazydocker.tgz" -C "$tmp" lazydocker
    install -m 0755 "$tmp/lazydocker" "$BIN/lazydocker"
    rm -rf "$tmp"
  else
    log "lazydocker already installed"
  fi

  if ! have_cmd ctop; then
    log "Installing ctop ${CTOP_VERSION}"
    download_to \
      "$BIN/ctop" \
      "https://github.com/bcicen/ctop/releases/download/v${CTOP_VERSION}/ctop-${CTOP_VERSION}-linux-${CTOP_BIN_ARCH}"
    chmod 0755 "$BIN/ctop"
  else
    log "ctop already installed"
  fi
}

write_profile() {
  log "Writing /etc/profile.d/eip-tools.sh"
  cat > /etc/profile.d/eip-tools.sh <<'EOF'
# EIP toolchain environment
export PATH="/usr/local/bin:$PATH"
_java_bin="$(command -v java 2>/dev/null)"
if [ -n "$_java_bin" ]; then
  export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$_java_bin")")")"
  export CODEQL_JAVA_HOME="$JAVA_HOME"
fi
unset _java_bin
export GHIDRA_INSTALL_DIR="/opt/ghidra"
export CODEQL_HOME="/opt/codeql"
EOF
  chmod 0644 /etc/profile.d/eip-tools.sh
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 50-base-tools.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/50-base-tools.sh"
    return $?
  fi
  detect_arch
  setup_context
  log "Target architecture: $ARCH"

  install_apt_prereqs
  configure_external_apt_repos
  install_apt_tools
  grant_current_user_permissions
  install_npm_tools
  install_pipx_tools
  install_docker_tuis
  write_profile

  if ((${#USER_PERMISSION_CHANGES[@]} > 0)); then
    log "$CURRENT_USER should log out and back in for new group membership: ${USER_PERMISSION_CHANGES[*]}"
  fi
}

verify() {
  local missing=()
  for cmd in rg jq curl git docker node npm npx semgrep mitmproxy pipx; do
    if need_cmd "$cmd"; then success "$cmd: $(command -v "$cmd")"; else missing+=("$cmd"); fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then warn "missing: ${missing[*]}"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
