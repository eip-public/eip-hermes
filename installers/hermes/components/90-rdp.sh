#!/usr/bin/env bash
# eip-hermes-component:
#   name: rdp
#   description: XFCE4 desktop + xrdp remote-desktop server
#   default: enabled
#   ports: 3389:xrdp
#   requires: preflight
#
# On by default — typical lab hosts are headed-ish (RDP'd into) rather than
# strict headless. Opt out for true headless installs with:
#
#   ./install.sh --skip rdp
#
# Most of the body is byte-identical with the upstream
# security-skills/scripts/install-rdp-ubuntu2404.sh script. Two intentional
# deviations:
#
#   [LIGHTDM-FIX]  AccountsService writes `Session=xfce` instead of
#                  `Session=` (empty); some LightDM versions treat an
#                  empty Session= as "no preferred session" and bounce
#                  the user back to the greeter. Matching XSession=xfce
#                  fixes local LightDM login (RDP login was unaffected).
#
#   [TERMINAL]     Adds xfce4-terminal to the apt install and points
#                  x-terminal-emulator at it, so panel launchers and
#                  "Open Terminal Here" stop opening plain xterm.
#
#   [BROWSER]      If Brave is installed (default via base-tools), wire
#                  it up as x-www-browser + xdg default-web-browser, so
#                  the XFCE panel's "Web Browser" launcher and xdg-open
#                  both route through Brave instead of being broken. Also
#                  swap the generic XFCE web-browser icon for Brave's, on
#                  both the system level (XDG override at /usr/local) and
#                  the current user's already-laid-out panel.
#
#   [REMMINA]      Installs Remmina + RDP/VNC/secret plugins (common need
#                  on a lab host that connects out to Windows targets and
#                  jump boxes) and adds a Remmina launcher to the system
#                  default XFCE panel layout at /etc/xdg/xfce4/panel/
#                  default.xml. The default layout is only copied into a
#                  user's $HOME the first time they start an XFCE session,
#                  so existing users keep their current panel (no surprise
#                  panel restarts); new sessions get the icon.

set -Eeuo pipefail

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER_DIR="$(cd "$COMPONENT_DIR/.." && pwd)"

if ! declare -f need_cmd >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$INSTALLER_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  set -a; source "$INSTALLER_DIR/defaults.env"; set +a
fi

# === component entry points ================================================

run() {
  if [ "$(id -u)" -ne 0 ]; then
    log "Re-executing 90-rdp.sh as root via sudo -E"
    sudo -E bash "$COMPONENT_DIR/90-rdp.sh"
    return $?
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    TARGET_USER="${SUDO_USER}"
  else
    TARGET_USER="$(id -un)"
  fi

  TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)"

  if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
    echo "Could not find home directory for ${TARGET_USER}" >&2
    exit 1
  fi

  sudo apt update
  sudo apt install -y xfce4 xfce4-goodies xfce4-terminal xrdp build-essential \
    remmina remmina-plugin-rdp remmina-plugin-vnc remmina-plugin-secret

  sudo systemctl enable --now xrdp

  # Make xfce4-terminal the default terminal so panel launchers,
  # "Open Terminal Here", and xdg-open all use it instead of plain xterm.
  # `--install` registers it (idempotent); `--set` then selects it. On some
  # Ubuntu builds the xfce4-terminal package doesn't ship its own
  # alternatives postinst, so just calling --set fails with
  # "alternative /usr/bin/xfce4-terminal for x-terminal-emulator not
  # registered" -- register first.
  if [[ -x /usr/bin/xfce4-terminal ]]; then
    sudo update-alternatives --install /usr/bin/x-terminal-emulator \
      x-terminal-emulator /usr/bin/xfce4-terminal 50 \
      || warn "Could not register xfce4-terminal in alternatives"
    sudo update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal \
      || warn "Could not set xfce4-terminal as default x-terminal-emulator"
  fi

  # If Brave is installed (base-tools with INSTALL_BRAVE=1, the default),
  # make it the default x-www-browser so the XFCE panel's "Web Browser"
  # launcher and xdg-open both route through it. Without this, the
  # ships-by-default panel browser icon is non-functional on a fresh
  # install. Same --install-then-set pattern as the terminal above.
  if [[ -x /usr/bin/brave-browser ]]; then
    sudo update-alternatives --install /usr/bin/x-www-browser \
      x-www-browser /usr/bin/brave-browser 50 \
      || warn "Could not register brave-browser in alternatives"
    sudo update-alternatives --set x-www-browser /usr/bin/brave-browser \
      || warn "Could not set brave-browser as default x-www-browser"
    # gvfs-mime / xdg-settings drives the XDG mimeapps default, which
    # exo-open and xdg-open prefer over update-alternatives on XFCE.
    if [[ -f /usr/share/applications/brave-browser.desktop ]] \
       && need_cmd xdg-settings; then
      sudo -u "$TARGET_USER" -H xdg-settings set default-web-browser brave-browser.desktop \
        2>/dev/null || warn "xdg-settings could not set default-web-browser"
    fi

    # Replace the generic XFCE web-browser icon with Brave's. Two places:
    #
    #   1. /usr/local/share/applications/xfce4-web-browser.desktop --
    #      XDG-precedence override so any future user whose panel is laid
    #      out from scratch picks up Brave's icon by default.
    #
    #   2. The current TARGET_USER's existing panel: when the panel
    #      launcher was first created, XFCE COPIED the upstream .desktop
    #      into ~/.config/xfce4/panel/launcher-NN/ -- the system override
    #      doesn't reach those retroactively. Find the copy whose
    #      X-XFCE-Source points at xfce4-web-browser.desktop and rewrite
    #      its Icon= line in place. Run sed via `sudo -u` so the file
    #      stays owned by TARGET_USER.
    sudo install -d -m 0755 /usr/local/share/applications
    sudo tee /usr/local/share/applications/xfce4-web-browser.desktop >/dev/null <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Exec=exo-open --launch WebBrowser %u
Icon=brave-browser
StartupNotify=true
Terminal=false
Categories=Network;X-XFCE;X-Xfce-Toplevel;
OnlyShowIn=XFCE;
X-XFCE-MimeType=x-scheme-handler/http;x-scheme-handler/https;
X-AppStream-Ignore=True
Name=Web Browser
Comment=Browse the web
EOF
    sudo chmod 0644 /usr/local/share/applications/xfce4-web-browser.desktop

    local panel_dir="$TARGET_HOME/.config/xfce4/panel"
    if [ -d "$panel_dir" ]; then
      local f
      while IFS= read -r f; do
        if grep -qE '^X-XFCE-Source=.*xfce4-web-browser\.desktop$' "$f" 2>/dev/null; then
          log "Updating panel browser icon in $f"
          sudo -u "$TARGET_USER" sed -i 's|^Icon=.*|Icon=brave-browser|' "$f" \
            || warn "Could not patch Icon= in $f"
        fi
      done < <(find "$panel_dir" -maxdepth 3 -type f -name '*.desktop' 2>/dev/null)
    fi
  fi

  # [REMMINA] Add a Remmina launcher to the system default XFCE panel.
  # /etc/xdg/xfce4/panel/default.xml is the layout xfce4-panel copies into
  # ~/.config/xfce4/panel/ the first time a user starts an XFCE session.
  # Editing it here means new users get the icon on first login without
  # any panel restart. Existing users (e.g. the one running the installer
  # who may already have a session) keep their current panel -- we don't
  # touch ~/.config to avoid disrupting a live session.
  local panel_default="/etc/xdg/xfce4/panel/default.xml"
  if [[ -f "$panel_default" ]] && [[ -f /usr/share/applications/org.remmina.Remmina.desktop ]]; then
    sudo python3 - "$panel_default" <<'PY'
import sys, xml.etree.ElementTree as ET
PATH = sys.argv[1]
REMMINA_DESKTOP = "org.remmina.Remmina.desktop"
tree = ET.parse(PATH)
root = tree.getroot()
plugins = root.find('property[@name="plugins"]')
panel2_ids = root.find('property[@name="panels"]/property[@name="panel-2"]/property[@name="plugin-ids"]')
if plugins is None or panel2_ids is None:
    print("default.xml schema unexpected -- skipping Remmina launcher", file=sys.stderr)
    sys.exit(0)
for p in plugins.findall("property"):
    if p.get("value") == "launcher":
        for items in p.findall('property[@name="items"]'):
            for v in items.findall("value"):
                if v.get("value") == REMMINA_DESKTOP:
                    print("Remmina launcher already present in default.xml")
                    sys.exit(0)
ids = [int(p.get("name").split("-",1)[1])
       for p in plugins.findall("property")
       if p.get("name","").startswith("plugin-")]
nid = max(ids) + 1
ET.SubElement(panel2_ids, "value", {"type": "int", "value": str(nid)})
np = ET.SubElement(plugins, "property",
                   {"name": f"plugin-{nid}", "type": "string", "value": "launcher"})
items = ET.SubElement(np, "property", {"name": "items", "type": "array"})
ET.SubElement(items, "value", {"type": "string", "value": REMMINA_DESKTOP})
ET.indent(tree, space="  ")
tree.write(PATH, encoding="UTF-8", xml_declaration=True)
print(f"Added Remmina launcher to default.xml as plugin-{nid}")
PY
  fi

  # Make both XRDP and the local LightDM GUI use the installed XFCE session.
  printf 'xfce4-session\n' | sudo tee "${TARGET_HOME}/.xsession" >/dev/null
  sudo chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.xsession"
  sudo chmod 0644 "${TARGET_HOME}/.xsession"

  printf '[Desktop]\nSession=xfce\n' | sudo tee "${TARGET_HOME}/.dmrc" >/dev/null
  sudo chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.dmrc"
  sudo chmod 0644 "${TARGET_HOME}/.dmrc"

  sudo mkdir -p /var/lib/AccountsService/users
  accounts_file="/var/lib/AccountsService/users/${TARGET_USER}"
  if [[ -f "${accounts_file}" ]]; then
    if sudo grep -q '^XSession=' "${accounts_file}"; then
      sudo sed -i 's/^XSession=.*/XSession=xfce/' "${accounts_file}"
    else
      printf 'XSession=xfce\n' | sudo tee -a "${accounts_file}" >/dev/null
    fi
    # [LIGHTDM-FIX] Also normalise Session= to xfce; an empty value here is
    # what was bouncing local LightDM logins back to the greeter.
    if sudo grep -q '^Session=' "${accounts_file}"; then
      sudo sed -i 's/^Session=.*/Session=xfce/' "${accounts_file}"
    else
      printf 'Session=xfce\n' | sudo tee -a "${accounts_file}" >/dev/null
    fi
  else
    # [LIGHTDM-FIX] Was: 'Session=\n' (empty). Now matches XSession.
    printf '[User]\nSession=xfce\nXSession=xfce\nSystemAccount=false\n' | sudo tee "${accounts_file}" >/dev/null
  fi

  sudo systemctl restart xrdp
  if systemctl is-active --quiet lightdm; then
    sudo systemctl restart lightdm
  fi

  # Disable automatic suspend.
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

  # Disable idle suspend in logind.
  sudo mkdir -p /etc/systemd/logind.conf.d
  sudo tee /etc/systemd/logind.conf.d/disable-suspend.conf >/dev/null <<'EOF'
[Login]
IdleAction=ignore
IdleActionSec=0
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

  sudo systemctl restart systemd-logind
}

verify() {
  if systemctl is-active --quiet xrdp; then
    success "xrdp service: active"
  else
    warn "xrdp service: not active"
  fi

  # systemctl restart returns before xrdp finishes binding 3389; give it up
  # to 10s before complaining (matches the wait loop in 30-control-plane).
  local listening=0 i
  for i in $(seq 1 10); do
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq ':3389$'; then
      listening=1; break
    fi
    sleep 1
  done
  if [ "$listening" = 1 ]; then
    success "RDP listening on :3389"
  else
    warn "RDP not listening on :3389"
  fi

  # /var/lib/AccountsService/users/<user> is 0600 root-only; read via
  # sudo_cmd so the check works whether verify runs in the sudo'd subprocess
  # or back in the orchestrator's non-root shell.
  local user accounts_file
  user="$(detect_setup_user)"
  accounts_file="/var/lib/AccountsService/users/$user"
  if sudo_cmd test -f "$accounts_file" 2>/dev/null; then
    if sudo_cmd grep -q '^Session=xfce' "$accounts_file" 2>/dev/null; then
      success "AccountsService Session=xfce set for $user"
    else
      warn "AccountsService Session= for $user is not 'xfce' (LightDM local login may bounce)"
    fi
  else
    warn "AccountsService file for $user not present"
  fi

  # Use plain readlink (single-level) on /etc/alternatives entries, not -f:
  # update-alternatives points at the registered binary path, which can
  # itself be a packaging symlink (e.g. /usr/bin/brave-browser ->
  # /opt/brave.com/brave/brave-browser). We want to compare against what
  # we registered, not the resolved canonical target.
  if [ -x /usr/bin/xfce4-terminal ]; then
    if [ "$(readlink /etc/alternatives/x-terminal-emulator 2>/dev/null)" = "/usr/bin/xfce4-terminal" ]; then
      success "default x-terminal-emulator: xfce4-terminal"
    else
      warn "default x-terminal-emulator is not /usr/bin/xfce4-terminal"
    fi
  else
    warn "xfce4-terminal not installed at /usr/bin/xfce4-terminal"
  fi

  if [ -x /usr/bin/brave-browser ]; then
    if [ "$(readlink /etc/alternatives/x-www-browser 2>/dev/null)" = "/usr/bin/brave-browser" ]; then
      success "default x-www-browser: brave-browser"
    else
      warn "default x-www-browser is not /usr/bin/brave-browser"
    fi
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  run
  verify
fi
