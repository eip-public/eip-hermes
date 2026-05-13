#!/usr/bin/env bash
# eip-hermes-component:
#   name: runtimes
#   description: apt prerequisites, Docker Engine + Compose, and uv
#   default: enabled
#   ports:
#   requires: preflight

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

install_apt_prereqs() {
  if [ "$INSTALL_APT" != true ]; then warn "Skipping apt prerequisite installation"; return 0; fi
  log "Installing apt prerequisites"
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y ca-certificates curl gnupg git jq python3 python3-venv python3-pip build-essential make openssl lsb-release
  success "Apt prerequisites installed"
}

install_docker_engine() {
  if need_cmd docker && docker compose version >/dev/null 2>&1; then
    success "Docker and Docker Compose are already available"
    return 0
  fi
  if [ "$INSTALL_DOCKER" != true ]; then
    fail "Docker/Compose not found and --skip-docker was set. Install Docker first."
  fi
  log "Installing Docker Engine from Docker's Ubuntu repository"
  sudo_cmd install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo_cmd tee /etc/apt/keyrings/docker.asc >/dev/null
    sudo_cmd chmod a+r /etc/apt/keyrings/docker.asc
  fi
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}")"
  echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" | sudo_cmd tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo_cmd systemctl enable --now docker
  if [ "$(id -u)" -ne 0 ]; then
    sudo_cmd usermod -aG docker "$USER" || true
    warn "Added $USER to docker group. If docker permission errors occur, log out/in or run: newgrp docker"
  fi
  success "Docker installed"
}

install_uv() {
  if need_cmd uv; then
    success "uv is already available: $(uv --version)"
    return 0
  fi
  log "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  need_cmd uv || fail "uv install completed but uv is not on PATH. Add ~/.local/bin to PATH and rerun."
  success "uv installed: $(uv --version)"
}

# === component entry points ================================================

run() {
  install_apt_prereqs
  install_docker_engine
  install_uv
}

verify() {
  if need_cmd docker; then success "docker on PATH: $(command -v docker)"; else warn "docker not on PATH"; fi
  if need_cmd uv; then success "uv on PATH: $(command -v uv)"; else warn "uv not on PATH"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
