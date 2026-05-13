#!/usr/bin/env bash
# eip-hermes-component:
#   name: runtime-langs
#   description: Language runtimes used by other security tools -- Go, Gradle, CodeQL
#   default: enabled
#   ports:
#   requires: base-tools

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

install_codeql() {
  if [[ ! -x /opt/codeql/codeql ]]; then
    log "Installing CodeQL CLI"
    local tmp
    tmp="$(mktemp -d)"
    rm -rf /opt/codeql
    download_to \
      "$tmp/codeql.zip" \
      https://github.com/github/codeql-cli-binaries/releases/latest/download/codeql-linux64.zip
    unzip -q "$tmp/codeql.zip" -d /opt
    rm -rf "$tmp"
  else
    log "CodeQL already installed"
  fi

  cat > "$BIN/codeql" <<'EOF'
#!/usr/bin/env bash
if [[ -z "${CODEQL_JAVA_HOME:-}" ]]; then
  _java="$(command -v java 2>/dev/null)"
  if [[ -n "$_java" ]]; then
    export CODEQL_JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$_java")")")"
  fi
fi
exec /opt/codeql/codeql "$@"
EOF
  chmod 0755 "$BIN/codeql"

  # The CLI zip includes extractors but not the query packs needed for `database analyze`.
  # Install the C/C++ query pack used by decompiler/security workflows into the user package cache.
  if [[ ! -d "$HOME/.codeql/packages/codeql/cpp-queries" ]]; then
    log "Installing CodeQL C/C++ query pack"
    "$BIN/codeql" pack download codeql/cpp-queries
  else
    log "CodeQL C/C++ query pack already installed"
  fi
}

install_go() {
  local dir="/opt/go-${GO_VERSION}"
  if [[ -x "$dir/bin/go" ]]; then
    log "Go ${GO_VERSION} already installed"
    ln -sfn "$dir" /opt/go
    ln -sf /opt/go/bin/go "$BIN/go"
    ln -sf /opt/go/bin/gofmt "$BIN/gofmt"
    return 0
  fi

  log "Installing Go ${GO_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  rm -rf "$dir"
  mkdir -p "$dir"
  download_to \
    "$tmp/go.tar.gz" \
    "https://go.dev/dl/go${GO_VERSION}.linux-${GOARCH}.tar.gz"
  tar xzf "$tmp/go.tar.gz" -C "$dir" --strip-components=1
  ln -sfn "$dir" /opt/go
  ln -sf /opt/go/bin/go "$BIN/go"
  ln -sf /opt/go/bin/gofmt "$BIN/gofmt"
  rm -rf "$tmp"
}

install_gradle() {
  local dir="/opt/gradle-${GRADLE_VERSION}"
  if [[ -x "$dir/bin/gradle" ]]; then
    log "Gradle ${GRADLE_VERSION} already installed"
    ln -sfn "$dir" /opt/gradle
    ln -sf /opt/gradle/bin/gradle "$BIN/gradle"
    return 0
  fi

  log "Installing Gradle ${GRADLE_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  download_to \
    "$tmp/gradle.zip" \
    "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
  unzip -q "$tmp/gradle.zip" -d /opt
  ln -sfn "$dir" /opt/gradle
  ln -sf /opt/gradle/bin/gradle "$BIN/gradle"
  rm -rf "$tmp"
}

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 75-runtime-langs.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/75-runtime-langs.sh"
    return $?
  fi
  detect_arch
  setup_context

  install_codeql
  install_go
  install_gradle

  # install_codeql's `pack download` runs `$BIN/codeql ...` while $HOME is
  # /root (sudo -E does not preserve HOME on Ubuntu by default), so the
  # cpp-queries pack ends up at /root/.codeql owned by root and is
  # invisible to the invoking user. Re-download into the user's home so
  # `codeql database analyze` finds it without --search-path.
  local target_user target_home
  target_user="$(detect_setup_user)"
  target_home="$(detect_setup_home "$target_user")"
  if [ -n "$target_home" ] && [ -x "$BIN/codeql" ] \
     && [ ! -d "$target_home/.codeql/packages/codeql/cpp-queries" ]; then
    log "Re-downloading CodeQL cpp-queries pack as $target_user (HOME=$target_home)"
    sudo -u "$target_user" -H "$BIN/codeql" pack download codeql/cpp-queries \
      || warn "codeql pack download as $target_user failed; pack remains at /root/.codeql/packages"
  fi
}

verify() {
  for cmd in go gradle codeql; do
    if need_cmd "$cmd"; then success "$cmd: $(command -v "$cmd")"; else warn "$cmd not on PATH"; fi
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
