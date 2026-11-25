#!/bin/bash
set -eo pipefail

# ==============================================================================
# Selkies (Wayland) + Pelorus - installer for LXC/LXD/Proxmox
#
# Supported operating systems:
#   - Debian 13 (Trixie)
#   - Ubuntu 26.04 LTS (Resolute Raccoon)
#
# Usage:
#   bash setup.sh [kde|xfce|sway] [--with-chrome|--no-chrome] [--selkies-only] [--packages-only] [--services-only] [--fix-session] [--no-cleanup]
#
#   --with-chrome    installs Google Chrome via install-chrome.sh (x86_64 only)
#   --no-chrome      skips Google Chrome installation without prompting
#   --selkies-only   installs Selkies only, skipping desktop environment packages
#                    (use when KDE, XFCE, or Sway is already installed)
#   --packages-only  installs only system packages and dependencies, then exits
#   --services-only  skips package installation; only configures the
#                    systemd --user services (useful after a failed install)
#   --fix-session    only repairs/checks the systemd user session, then exits
#   --no-cleanup     skips automatic removal of previous Selkies components during update
#
# Variables:
#   DESKTOP_ENV=kde|xfce|sway   INSTALL_CHROME=yes|no   SELKIES_ONLY=0|1   PACKAGES_ONLY=0|1
#   SERVICES_ONLY=0|1           SKIP_CLEANUP=0|1        PASSWORD=...       SETUP_USER=<user> (when running as root)
# ==============================================================================

# The script must run from its own directory (it copies files via relative paths)
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$SCRIPT_DIR"
INSTALL_LOG="/tmp/selkies-lxd-wayland-install.log"

# ---------- Argument parsing ----------
PACKAGES_ONLY="${PACKAGES_ONLY:-0}"
SERVICES_ONLY="${SERVICES_ONLY:-0}"
SELKIES_ONLY="${SELKIES_ONLY:-0}"
SKIP_CLEANUP="${SKIP_CLEANUP:-0}"
FIX_SESSION_ONLY=0
ORIG_ARGS=("$@")
for arg in "$@"; do
  case "$arg" in
    --packages-only|--package-only) PACKAGES_ONLY=1 ;;
    --services-only) SERVICES_ONLY=1 ;;
    --selkies-only|--no-desktop|--skip-de) SELKIES_ONLY=1 ;;
    --no-cleanup)    SKIP_CLEANUP=1 ;;
    --fix-session)   FIX_SESSION_ONLY=1 ;;
    --with-chrome)   INSTALL_CHROME="yes" ;;
    --no-chrome)     INSTALL_CHROME="no" ;;
    kde|KDE|xfce|XFCE|sway|SWAY) DESKTOP_ENV="${arg,,}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

if [ "$PACKAGES_ONLY" = "1" ] && [ "$SERVICES_ONLY" = "1" ]; then
  die "Cannot specify both --packages-only and --services-only."
fi

log()  { echo "[setup] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ==============================================================================
# OS detection and validation
# Supported: Debian 13 (Trixie)  |  Ubuntu 26.04 LTS (Resolute Raccoon)
# ==============================================================================
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_VERSION_ID="${VERSION_ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
  else
    die "/etc/os-release not found - cannot detect operating system."
  fi

  case "${OS_ID}" in
    debian)
      if [ "${OS_VERSION_ID}" = "13" ] || [ "${OS_VERSION_CODENAME}" = "trixie" ]; then
        DISTRO="debian"
        DISTRO_LABEL="Debian 13 (Trixie)"
        echo "[OK] Detected supported OS: ${DISTRO_LABEL}"
      else
        die "Unsupported Debian version: ${OS_PRETTY}
Supported versions:
  - Debian 13 (Trixie)
  - Ubuntu 26.04 LTS (Resolute Raccoon)"
      fi
      ;;
    ubuntu)
      if [ "${OS_VERSION_ID}" = "26.04" ] || [ "${OS_VERSION_CODENAME}" = "resolute" ]; then
        DISTRO="ubuntu"
        DISTRO_LABEL="Ubuntu 26.04 LTS (Resolute Raccoon)"
        echo "[OK] Detected supported OS: ${DISTRO_LABEL}"
      else
        die "Unsupported Ubuntu version: ${OS_PRETTY}
Supported versions:
  - Debian 13 (Trixie)
  - Ubuntu 26.04 LTS (Resolute Raccoon)"
      fi
      ;;
    *)
      die "Unsupported operating system: ${OS_PRETTY}
Supported systems:
  - Debian 13 (Trixie)
  - Ubuntu 26.04 LTS (Resolute Raccoon)"
      ;;
  esac

  export DISTRO DISTRO_LABEL
}

detect_os

# ==============================================================================
# systemd user session handling (fixes the pct enter / pct exec / su problem)
# ==============================================================================

# Started as root (e.g. `pct enter`): switch to a regular user via
# `runuser -l` (login shell) so that HOME, USER and $0 are correct.
reexec_as_user_if_root() {
  [ "$(id -u)" -eq 0 ] || return 0

  local target="${SETUP_USER:-}"
  if [ -z "$target" ]; then
    # If the system has exactly one regular user, use that one
    mapfile -t users < <(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1}')
    if [ "${#users[@]}" -eq 1 ]; then
      target="${users[0]}"
      log "Running as root - using the only regular user: $target"
    else
      die "This script cannot run as root. Run it as a regular user with sudo, or specify:
         SETUP_USER=<username> bash setup.sh
       Available users: ${users[*]:-none (create one: adduser <name> && usermod -aG sudo <name>)}"
    fi
  fi
  id "$target" >/dev/null 2>&1 || die "User '$target' does not exist."

  # The user needs access to the scripts directory and the install log in /tmp
  chmod -R a+rX "$SCRIPT_DIR" 2>/dev/null || true
  if [ -e "$INSTALL_LOG" ]; then
    chown "$target" "$INSTALL_LOG" 2>/dev/null || rm -f "$INSTALL_LOG" 2>/dev/null || true
  fi

  local envs="" v
  for v in DESKTOP_ENV INSTALL_CHROME CHROME_EXTRA_FLAGS PASSWORD CUSTOM_PORT CUSTOM_HTTPS_PORT CUSTOM_WS_PORT SUBFOLDER DASHBOARD \
           DISABLE_IPV6 SELKIES_FILE_TRANSFERS HARDEN_DESKTOP PELORUS SELKIES_IMAGE SERVICES_ONLY PACKAGES_ONLY SELKIES_ONLY SKIP_CLEANUP; do
    [ -n "${!v:-}" ] && envs+=" $(printf '%s=%q' "$v" "${!v}")"
  done
  local args=""
  [ "${#ORIG_ARGS[@]}" -gt 0 ] && args="$(printf ' %q' "${ORIG_ARGS[@]}")"

  log "Switching to user '$target' (login shell)..."
  exec runuser -l "$target" -c "cd $(printf '%q' "$SCRIPT_DIR") && env${envs} bash setup.sh${args}"
}

# Is the systemd --user session usable?
user_session_ok() {
  systemctl --user show-environment >/dev/null 2>&1
}

# Repairs the user session: linger + user@UID.service + environment variables.
# $1 = "hard" -> fatal error on failure; "soft" -> warning only.
ensure_user_session() {
  local mode="${1:-hard}" uid
  uid="$(id -u)"

  # systemd must be PID 1
  if [ ! -d /run/systemd/system ]; then
    [ "$mode" = "hard" ] && die "systemd is not the init system (PID 1) in this container - user services will not work."
    warn "systemd is not the init system - skipping session check."
    return 1
  fi

  # Force correct variables (pct enter/su may leave e.g. root's XDG_RUNTIME_DIR)
  export XDG_RUNTIME_DIR="/run/user/${uid}"
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"

  if user_session_ok; then
    log "systemd --user session is working (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)."
    sudo loginctl enable-linger "$USER" 2>/dev/null || true
    return 0
  fi

  log "No systemd --user session (typical for pct enter / pct exec / su). Repairing..."

  # 1. Linger: systemd keeps the user session alive without a login
  sudo loginctl enable-linger "$USER" 2>/dev/null || warn "loginctl enable-linger failed"

  # 2. Start user@UID.service (creates /run/user/UID and the systemd --user manager)
  sudo systemctl start "user@${uid}.service" 2>/dev/null || warn "systemctl start user@${uid}.service failed"

  # 3. Wait for the D-Bus socket
  local i
  for i in $(seq 1 30); do
    [ -S "${XDG_RUNTIME_DIR}/bus" ] && break
    sleep 0.5
  done

  # 4. If user@ started before dbus-user-session was installed, restart it (nothing runs in it yet)
  if [ ! -S "${XDG_RUNTIME_DIR}/bus" ]; then
    log "No D-Bus socket - restarting user@${uid}.service..."
    sudo systemctl restart "user@${uid}.service" 2>/dev/null || true
    for i in $(seq 1 30); do
      [ -S "${XDG_RUNTIME_DIR}/bus" ] && break
      sleep 0.5
    done
  fi

  if user_session_ok; then
    log "systemd --user session repaired."
    return 0
  fi

  cat >&2 <<EOF

[ERROR] Failed to start a systemd --user session for '$USER' (UID $uid).

Diagnostics:
  /run/user/$uid:   $(ls -ld "/run/user/$uid" 2>&1 | head -n1)
  user@$uid.service: $(systemctl is-active "user@${uid}.service" 2>&1)
  dbus-user-session: $(dpkg -s dbus-user-session 2>/dev/null | grep -m1 '^Status' || echo 'NOT INSTALLED')
  virtualization:   $(systemd-detect-virt 2>/dev/null || echo '?')

What to check:
  * On the Proxmox host:   pct set <CTID> --features nesting=1,keyctl=1  (then: pct reboot <CTID>)
  * Log in via SSH as '$USER' and run the script again.
  * Finish without reinstalling packages:   bash setup.sh --services-only
EOF
  [ "$mode" = "hard" ] && exit 1
  return 1
}

# ==============================================================================
# Main
# ==============================================================================
reexec_as_user_if_root
: "${USER:=$(id -un)}"
export USER

# Make sure sudo works up front (avoids surprises midway through the installation)
command -v sudo >/dev/null 2>&1 || die "'sudo' not found. As root: apt install sudo && usermod -aG sudo $USER"
if ! sudo -v; then
  die "User '$USER' does not have sudo privileges."
fi

# Set up full installation logging to /tmp/selkies-lxd-wayland-install.log
if [ -e "$INSTALL_LOG" ] && [ ! -w "$INSTALL_LOG" ]; then
  sudo chown "$USER:$(id -gn)" "$INSTALL_LOG" 2>/dev/null || sudo rm -f "$INSTALL_LOG" 2>/dev/null || true
fi
touch "$INSTALL_LOG"
chmod 644 "$INSTALL_LOG" 2>/dev/null || true
export SELKIES_LOGGING_ACTIVE=1
exec > >(tee -a "$INSTALL_LOG") 2>&1

echo "=== Starting Selkies (Wayland) + Pelorus installation on LXC ($(date -Is)) ==="
log "Operating system : $DISTRO_LABEL"
log "Logging full installation output to: $INSTALL_LOG"

# Session-repair-only mode
if [ "$FIX_SESSION_ONLY" = "1" ]; then
  ensure_user_session hard
  echo "OK: the user session is working."
  exit 0
fi

# Soft check at startup (full repair happens after the packages are installed)
if [ "$SERVICES_ONLY" != "1" ] && [ "$PACKAGES_ONLY" != "1" ]; then
  user_session_ok || warn "systemd --user session is not active - it will be repaired automatically during installation."
fi

# 1. Verify supported CPU architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64)
    echo "[OK] Supported CPU architecture: $ARCH"
    ;;
  *)
    echo "ERROR: Unsupported CPU architecture '$ARCH'. Only x86_64 and aarch64 are supported." >&2
    exit 1
    ;;
esac

export PATH="$HOME/.local/bin:$PATH"

if [ "$SERVICES_ONLY" = "1" ]; then
  log "--services-only mode: skipping package and component installation."
  ensure_user_session hard
else

# Detect whether a desktop environment is already installed on the system
detect_installed_de() {
  if command -v plasmashell >/dev/null 2>&1 || command -v startplasma-wayland >/dev/null 2>&1 || [ -f /usr/bin/plasmashell ]; then
    echo "kde"
  elif command -v xfce4-session >/dev/null 2>&1 || [ -f /usr/bin/xfce4-session ]; then
    echo "xfce"
  elif command -v sway >/dev/null 2>&1 || [ -f /usr/bin/sway ]; then
    echo "sway"
  else
    echo ""
  fi
}

# Check whether Selkies or any of its components are already installed on the system
is_selkies_installed() {
  if [ -d /lsiopy ] || \
     [ -d /usr/share/selkies ] || \
     [ -f /usr/lib/selkies_input_interposer.so ] || \
     [ -f /usr/lib/selkies_joystick_interposer.so ] || \
     [ -f /usr/local/bin/selkies ] || \
     [ -f /usr/local/bin/pelorus ] || \
     [ -f /usr/local/bin/selkies-startwm-wayland.sh ] || \
     [ -f /usr/local/bin/kwin-xwayland.py ] || \
     [ -f /usr/local/bin/selkies-proot ] || \
     [ -f /usr/bin/selkies-desktop ] || \
     [ -f "$HOME/.config/systemd/user/selkies.service" ] || \
     [ -f "$HOME/.config/systemd/user/desktop.service" ] || \
     systemctl --user is-active --quiet selkies 2>/dev/null || \
     systemctl --user is-enabled --quiet selkies 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Remove all existing Selkies components prior to reinstallation (clean update)
remove_existing_selkies() {
  log "Existing Selkies installation detected - removing previous components for clean update..."

  # 1. Stop and disable systemd user services
  log "Stopping and disabling Selkies user services..."
  systemctl --user stop desktop.service selkies.service 2>/dev/null || true
  systemctl --user disable desktop.service selkies.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/selkies.service" "$HOME/.config/systemd/user/desktop.service"
  systemctl --user daemon-reload 2>/dev/null || true

  # 2. Terminate any running Selkies, Pelorus, or session processes
  log "Terminating running Selkies and Pelorus processes..."
  pkill -9 -f '/lsiopy/bin/selkies' 2>/dev/null || true
  pkill -9 -f '/lsiopy/bin/pelorus' 2>/dev/null || true
  pkill -9 -f 'selkies-startwm-wayland' 2>/dev/null || true
  pkill -9 -f 'kwin-xwayland.py' 2>/dev/null || true

  # 3. Remove installed binaries and session scripts
  log "Removing installed Selkies binaries and scripts..."
  sudo rm -f /usr/local/bin/selkies \
             /usr/local/bin/pelorus \
             /usr/local/bin/selkies-startwm-wayland.sh \
             /usr/local/bin/kwin-xwayland.py \
             /usr/local/bin/selkies-proot \
             /usr/bin/selkies-desktop

  # 4. Remove Selkies interposer libraries and fake libudev
  log "Removing Selkies libraries..."
  sudo rm -f /usr/lib/selkies_input_interposer.so \
             /usr/lib/selkies_joystick_interposer.so \
             /usr/lib/selkies_v4l2_interposer.so \
             /opt/lib/libudev.so.1.0.0-fake

  # 5. Remove Selkies virtual environment, web assets, and proot-apps
  log "Removing /lsiopy, /usr/share/selkies, and /proot-apps..."
  sudo rm -rf /lsiopy /usr/share/selkies /proot-apps
  rm -f "$HOME/.local/bin/proot" "$HOME/.local/bin/proot-apps" "$HOME/.local/bin/bwrap" "$HOME/.local/bin/jq" 2>/dev/null || true

  # 6. Remove PulseAudio custom configuration
  sudo rm -f /etc/pulse/default.pa.d/selkies.pa

  # 7. Remove temporary udocker containers
  if command -v udocker >/dev/null 2>&1; then
    udocker rm -f selkies_tmp 2>/dev/null || true
  fi

  # 8. Clean up runtime logs and temporary sockets
  rm -f /tmp/pelorus.log
  sudo rm -f /tmp/.X11-unix/X* 2>/dev/null || true

  # 9. Backup existing environment configuration if present
  if [ -f "$HOME/.config/selkies/selkies.env" ]; then
    cp -f "$HOME/.config/selkies/selkies.env" "$HOME/.config/selkies/selkies.env.bak"
    rm -f "$HOME/.config/selkies/selkies.env"
    log "Backed up existing selkies.env to ~/.config/selkies/selkies.env.bak"
  fi

  echo "[OK] Previous Selkies components removed successfully."
}

# 2. Select Desktop Environment (KDE, XFCE, or Sway) and installation mode
detected_de="$(detect_installed_de)"

DESKTOP_ENV="${DESKTOP_ENV:-}"
if [ -z "$DESKTOP_ENV" ] && [ -f ~/.config/selkies/selkies.env ]; then
  saved_de=$(grep "^DESKTOP_ENVIRONMENT=" ~/.config/selkies/selkies.env 2>/dev/null | cut -d= -f2- | tr -d ' "\r' || true)
  [ -n "$saved_de" ] && DESKTOP_ENV="$saved_de"
fi

if [ -z "$DESKTOP_ENV" ]; then
  if [ "$SELKIES_ONLY" = "1" ]; then
    # In Selkies-only mode without explicit DE: use detected DE if available, or ask
    if [ -n "$detected_de" ]; then
      DESKTOP_ENV="$detected_de"
      log "Auto-detected existing desktop environment for Selkies: $DESKTOP_ENV"
    elif [ -t 0 ]; then
      echo "--------------------------------------------------"
      echo "Select existing Desktop Environment to integrate with Selkies:"
      echo "  1) KDE Plasma (Wayland) [default]"
      echo "  2) XFCE (Wayland + Labwc)"
      echo "  3) Sway (Wayland tiling compositor)"
      echo "--------------------------------------------------"
      read -rp "Enter choice [1-3, default 1]: " de_choice || de_choice=""
      case "$de_choice" in
        2|xfce|XFCE) DESKTOP_ENV="xfce" ;;
        3|sway|SWAY) DESKTOP_ENV="sway" ;;
        *)           DESKTOP_ENV="kde" ;;
      esac
    else
      DESKTOP_ENV="kde"
    fi
  elif [ -t 0 ]; then
    echo "--------------------------------------------------"
    if [ -n "$detected_de" ]; then
      case "$detected_de" in
        kde)  echo "Detected installed desktop: KDE Plasma (plasmashell)" ;;
        xfce) echo "Detected installed desktop: XFCE (xfce4-session)" ;;
        sway) echo "Detected installed desktop: Sway (sway)" ;;
        *)    echo "Detected installed desktop: $detected_de" ;;
      esac
    fi
    echo "Select Desktop Environment / Installation Mode:"
    echo "  1) Install KDE Plasma (Wayland) [default]"
    echo "  2) Install XFCE (Wayland + Labwc)"
    echo "  3) Install Sway (Wayland tiling compositor)"
    echo "  4) Selkies only with existing KDE Plasma (skip desktop packages)"
    echo "  5) Selkies only with existing XFCE (skip desktop packages)"
    echo "  6) Selkies only with existing Sway (skip desktop packages)"
    echo "--------------------------------------------------"
    read -rp "Enter choice [1-6, default 1]: " de_choice || de_choice=""
    case "$de_choice" in
      2|xfce|XFCE)
        DESKTOP_ENV="xfce"
        SELKIES_ONLY=0
        ;;
      3|sway|SWAY)
        DESKTOP_ENV="sway"
        SELKIES_ONLY=0
        ;;
      4)
        DESKTOP_ENV="kde"
        SELKIES_ONLY=1
        ;;
      5)
        DESKTOP_ENV="xfce"
        SELKIES_ONLY=1
        ;;
      6)
        DESKTOP_ENV="sway"
        SELKIES_ONLY=1
        ;;
      *)
        DESKTOP_ENV="kde"
        SELKIES_ONLY=0
        ;;
    esac
  else
    DESKTOP_ENV="kde"
  fi
fi

case "${DESKTOP_ENV,,}" in
  xfce)
    DESKTOP_ENV="xfce"
    ;;
  sway)
    DESKTOP_ENV="sway"
    ;;
  *)
    DESKTOP_ENV="kde"
    ;;
esac
if [ "$SELKIES_ONLY" = "1" ]; then
  echo "[OK] Selected Mode: Selkies only (using existing $DESKTOP_ENV desktop)"
else
  echo "[OK] Selected Desktop Environment: $DESKTOP_ENV (full install)"
fi

# 2b. Ask whether to install Google Chrome (x86_64 only)
INSTALL_CHROME="${INSTALL_CHROME:-}"
if [ "$ARCH" = "x86_64" ]; then
  if [ -z "$INSTALL_CHROME" ]; then
    if [ -t 0 ]; then
      echo "--------------------------------------------------"
      echo "Do you want to install Google Chrome (Wayland + VA-API GPU support)?"
      echo "--------------------------------------------------"
      read -rp "Install Google Chrome? [y/N]: " chrome_choice || chrome_choice=""
      case "${chrome_choice,,}" in
        y|yes|1|true)
          INSTALL_CHROME="yes"
          ;;
        *)
          INSTALL_CHROME="no"
          ;;
      esac
    else
      INSTALL_CHROME="no"
    fi
  fi
  case "${INSTALL_CHROME,,}" in
    y|yes|1|true)
      INSTALL_CHROME="yes"
      ;;
    *)
      INSTALL_CHROME="no"
      ;;
  esac
  echo "[OK] Install Google Chrome: $INSTALL_CHROME"
else
  if [[ "${INSTALL_CHROME,,}" =~ ^(y|yes|1|true)$ ]]; then
    warn "Google Chrome is only available for x86_64 (current: $ARCH) - skipping."
  fi
  INSTALL_CHROME="no"
fi

# 3. Set variables
echo "[OK] Variables Set"

# 3b. Clean up previous Selkies installation if present (clean update mode)
if [ "$SERVICES_ONLY" != "1" ] && [ "$PACKAGES_ONLY" != "1" ] && [ "${SKIP_CLEANUP:-0}" != "1" ]; then
  if is_selkies_installed; then
    remove_existing_selkies
  fi
fi

# 4. Create required directories
mkdir -p ~/.config/rclone ~/.config/selkies ~/.config/systemd/user "$HOME/Desktop"
sudo mkdir -p /root/.config/rclone
touch ~/.config/rclone/rclone.conf
sudo touch /root/.config/rclone/rclone.conf

# 5. Install system packages
if [ "$DISTRO" = "debian" ]; then
  if [ "$ARCH" = "x86_64" ]; then
    echo "--- Enabling APT non-free component for x86_64 GPU drivers (Debian) ---"
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then
      sudo sed -i -E '/^Components:/ { /(^|[[:space:]])non-free([[:space:]]|$)/! s/$/ non-free/ }' /etc/apt/sources.list.d/debian.sources
    fi
    if [ -f /etc/apt/sources.list ]; then
      sudo sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]]+.*debian/ { /(^|[[:space:]])non-free([[:space:]]|$)/! s/$/ non-free/ }' /etc/apt/sources.list
    fi
  fi
elif [ "$DISTRO" = "ubuntu" ]; then
  echo "--- Enabling Ubuntu universe and restricted repositories for GPU drivers ---"
  sudo add-apt-repository -y universe 2>/dev/null || true
  sudo add-apt-repository -y restricted 2>/dev/null || true
  # Add Mozilla Team PPA to get a proper .deb Firefox instead of the Snap redirect (skip in Selkies-only mode)
  if { [ "$DESKTOP_ENV" = "xfce" ] || [ "$DESKTOP_ENV" = "sway" ]; } && [ "$SELKIES_ONLY" != "1" ]; then
    echo "--- Adding Mozilla Team PPA for Firefox .deb package (Ubuntu) ---"
    sudo add-apt-repository -y ppa:mozillateam/ppa 2>/dev/null || warn "Failed to add Mozilla PPA; Firefox snap may be used instead."
    # Prioritize the .deb over the snap redirect
    sudo tee /etc/apt/preferences.d/mozilla-firefox > /dev/null <<'APT_PREF'
Package: firefox*
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
APT_PREF
  fi
fi

if [ "$SELKIES_ONLY" = "1" ]; then
  echo "--- Updating repositories and installing Selkies packages for existing $DESKTOP_ENV on $DISTRO_LABEL ---"
else
  echo "--- Updating repositories and installing system packages for $DESKTOP_ENV on $DISTRO_LABEL ---"
fi
sudo apt update

COMMON_PACKAGES=(
  acl curl git libepoxy0 libnginx-mod-http-fancyindex locales-all nginx pipx pulseaudio pulseaudio-utils ssl-cert unzip
  x11-xkb-utils xcvt xdotool xclip xsel xwayland
  at-spi2-core dbus-user-session wl-clipboard python3 python3-pip
  python3-gi python3-gi-cairo gir1.2-atspi-2.0 gir1.2-gtk-3.0 foot
)

ARCH_PACKAGES=()
if [ "$ARCH" = "x86_64" ]; then
  if [ "$DISTRO" = "debian" ]; then
    # Full Intel VA-API driver with hardware encoding and video processing support (e.g. HD Graphics 530 / Gen8+)
    ARCH_PACKAGES=(
      vainfo libva2 libva-drm2 libva-wayland2 mesa-va-drivers intel-media-va-driver-non-free
    )
  elif [ "$DISTRO" = "ubuntu" ]; then
    # Ubuntu ships intel-media-va-driver in the restricted repo (no -non-free suffix)
    ARCH_PACKAGES=(
      vainfo libva2 libva-drm2 libva-wayland2 mesa-va-drivers intel-media-va-driver
    )
  fi
fi

if [ "$SELKIES_ONLY" = "1" ]; then
  echo "--- Selkies-only mode: skipping desktop environment packages (using existing $DESKTOP_ENV) ---"
  if [ "$DESKTOP_ENV" = "xfce" ]; then
    DE_PACKAGES=(labwc)
  elif [ "$DESKTOP_ENV" = "sway" ]; then
    DE_PACKAGES=(sway)
  else
    DE_PACKAGES=(kwin-wayland qt6-wayland)
  fi
else
  if [ "$DESKTOP_ENV" = "xfce" ]; then
    if [ "$DISTRO" = "ubuntu" ]; then
      DE_PACKAGES=(
        xfce4 xfce4-terminal xfce4-goodies firefox labwc mate-polkit adwaita-icon-theme
      )
    else
      DE_PACKAGES=(
        xfce4 xfce4-terminal xfce4-goodies firefox-esr labwc mate-polkit adwaita-icon-theme
      )
    fi
  elif [ "$DESKTOP_ENV" = "sway" ]; then
    if [ "$DISTRO" = "ubuntu" ]; then
      DE_PACKAGES=(
        sway swaybg swayidle swaylock waybar wofi mako-notifier xdg-desktop-portal-wlr mate-polkit adwaita-icon-theme firefox
      )
    else
      DE_PACKAGES=(
        sway swaybg swayidle swaylock waybar wofi mako-notifier xdg-desktop-portal-wlr mate-polkit adwaita-icon-theme firefox-esr
      )
    fi
  else
    if [ "$DISTRO" = "ubuntu" ]; then
      # Ubuntu: plasma-welcome does not exist as a separate package; skip exclusion marker
      DE_PACKAGES=(
        kde-plasma-desktop kwin-wayland qt6-wayland polkit-kde-agent-1 libkf6config-bin libkf6service-bin
        plasma-nm-
      )
    else
      # Exclude plasma-nm and plasma-welcome (marked with trailing '-') from kde-plasma-desktop recommendations
      DE_PACKAGES=(
        kde-plasma-desktop kwin-wayland qt6-wayland polkit-kde-agent-1 libkf6config-bin libkf6service-bin
        plasma-nm- plasma-welcome-
      )
    fi
  fi
fi

sudo DEBIAN_FRONTEND=noninteractive apt install -yq "${COMMON_PACKAGES[@]}" "${ARCH_PACKAGES[@]}" "${DE_PACKAGES[@]}"
sudo apt clean

# After dbus-user-session is installed: make sure the user session works
if [ "$PACKAGES_ONLY" = "1" ]; then
  ensure_user_session soft || true
else
  ensure_user_session hard
fi

# 6. Install rclone (if not present)
if ! command -v rclone >/dev/null 2>&1; then
  echo "--- Installing rclone ---"
  curl -fsSL https://rclone.org/install.sh | sudo bash
fi

# 7. Add user to audio, video, and render groups & verify /dev/dri group IDs
sudo groupadd -f video
sudo groupadd -f render
sudo usermod -aG audio,video,render "$USER"

verify_dri_groups() {
  if [ ! -d /dev/dri ]; then
    log "No /dev/dri directory present (GPU passthrough not configured yet)."
    return 0
  fi

  local video_gid render_gid dev expected_grp expected_gid dev_gid dev_grp has_error=0
  video_gid="$(getent group video | cut -d: -f3)"
  render_gid="$(getent group render | cut -d: -f3)"
  log "Checking /dev/dri device group IDs (container groups: video=$video_gid, render=$render_gid)..."

  shopt -s nullglob
  for dev in /dev/dri/card* /dev/dri/renderD*; do
    case "$(basename "$dev")" in
      card*)    expected_grp="video";  expected_gid="$video_gid" ;;
      renderD*) expected_grp="render"; expected_gid="$render_gid" ;;
      *)        continue ;;
    esac

    dev_gid="$(stat -c '%g' "$dev" 2>/dev/null || true)"
    dev_grp="$(stat -c '%G' "$dev" 2>/dev/null || true)"

    if [ "$dev_gid" = "$expected_gid" ]; then
      echo "[OK] $dev has correct group '$expected_grp' (GID $dev_gid)."
    else
      echo "[ERROR] Invalid group on $dev: found '$dev_grp' (GID $dev_gid), expected '$expected_grp' (GID $expected_gid)." >&2
      has_error=1
    fi
  done
  shopt -u nullglob

  if [ "$has_error" -eq 1 ]; then
    echo "[ERROR] Invalid groups on devices in /dev/dri." >&2
  fi
}
verify_dri_groups

# Early exit for --packages-only mode
if [ "$PACKAGES_ONLY" = "1" ]; then
  if [ "${INSTALL_CHROME:-no}" = "yes" ]; then
    echo "--- Installing Google Chrome via install-chrome.sh ---"
    bash "$SCRIPT_DIR/install-chrome.sh"
  fi
  echo "=== Package installation completed successfully (--packages-only) ($(date -Is)) ==="
  log "All required system packages and dependencies have been installed."
  log "Installation log saved to: $INSTALL_LOG"
  exit 0
fi

# 8. Pull and extract Selkies components via udocker
echo "--- Pulling Selkies image via udocker ---"
pipx install udocker 2>/dev/null || pipx upgrade udocker 2>/dev/null || true
# Select the appropriate LinuxServer.io Selkies base image for the detected OS
if [ -z "${SELKIES_IMAGE:-}" ]; then
  if [ "$DISTRO" = "ubuntu" ]; then
    SELKIES_IMAGE="lsiobase/selkies:ubunturesolute-87420d8d-ls41"
    echo "[INFO] Using Ubuntu Resolute Raccoon Selkies image: $SELKIES_IMAGE"
  else
    SELKIES_IMAGE="lsiobase/selkies:debiantrixie-60ce2ea6-ls152"
    echo "[INFO] Using Debian Trixie Selkies image: $SELKIES_IMAGE"
  fi
fi
export SELKIES_TAG="${SELKIES_IMAGE#*:}"
udocker pull "$SELKIES_IMAGE"
udocker create --name=selkies_tmp "$SELKIES_IMAGE"

export SELKIES_ROOTFS="$(find ~/.udocker -name selkies_input_interposer.so | sed 's|/usr/lib/selkies_input_interposer.so||' | head -n 1)"
if [ -z "$SELKIES_ROOTFS" ] || [ ! -d "$SELKIES_ROOTFS" ]; then
  echo "ERROR: Could not find SELKIES_ROOTFS in ~/.udocker!" >&2
  exit 1
fi
echo "Located image rootfs: $SELKIES_ROOTFS"

echo "--- Copying Selkies binaries and libraries ---"
sudo rclone copy -L "$SELKIES_ROOTFS/usr/lib/selkies_input_interposer.so" /usr/lib/
sudo ln -sf /usr/lib/selkies_input_interposer.so /usr/lib/selkies_joystick_interposer.so
if [ -f "$SELKIES_ROOTFS/usr/lib/selkies_v4l2_interposer.so" ]; then
  sudo rclone copy -L "$SELKIES_ROOTFS/usr/lib/selkies_v4l2_interposer.so" /usr/lib/
fi
sudo rclone copy -L "$SELKIES_ROOTFS/opt/lib/libudev.so.1.0.0-fake" /opt/lib/
if [ -f "$SELKIES_ROOTFS/usr/bin/selkies-desktop" ]; then
  sudo rclone copy -L "$SELKIES_ROOTFS/usr/bin/selkies-desktop" /usr/bin/
  sudo chmod 755 /usr/bin/selkies-desktop
fi
if [ -f "$SELKIES_ROOTFS/usr/local/bin/selkies-proot" ]; then
  sudo rclone copy -L "$SELKIES_ROOTFS/usr/local/bin/selkies-proot" /usr/local/bin/
  # The LinuxServer image uses an s6-overlay shebang (with-contenv) that does not
  # exist in a plain LXC without Docker. Without this fix, Selkies cannot run the
  # startup check 'selkies-proot check' and hides the Apps section in the sidebar.
  sudo sed -i '1s|^#!.*with-contenv.*|#!/bin/bash|' /usr/local/bin/selkies-proot
  sudo chmod 755 /usr/local/bin/selkies-proot
else
  echo "[WARNING] selkies-proot not found in the image - the Selkies Apps section will be hidden." >&2
fi
if [ -d "$SELKIES_ROOTFS/proot-apps" ]; then
  echo "--- Installing proot-apps for Selkies Apps menu ---"
  sudo rclone copy -L "$SELKIES_ROOTFS/proot-apps" /proot-apps
  sudo chmod -R a+rX /proot-apps
  mkdir -p "$HOME/.local/bin"
  cp -a /proot-apps/* "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/proot" "$HOME/.local/bin/proot-apps" "$HOME/.local/bin/jq" 2>/dev/null || true
  ln -sfn proot "$HOME/.local/bin/bwrap"
  rm -f "$HOME/.local/bin/proot-bwrap"
  if ! grep -qsF 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi
  if ! grep -qsF 'source <(proot-apps completion bash)' "$HOME/.bashrc" 2>/dev/null; then
    echo 'source <(proot-apps completion bash)' >> "$HOME/.bashrc"
  fi
fi
sudo rclone copy -L "$SELKIES_ROOTFS/lsiopy" /lsiopy
sudo rclone copy -L "$SELKIES_ROOTFS/usr/share/selkies" /usr/share/selkies
sudo chmod -R a+rX /usr/share/selkies
sudo chmod -R a+rX /lsiopy
sudo chmod a+x /lsiopy/bin/*

# Check and install Pelorus if missing from extracted venv.
# Pelorus is NOT set up for Sway: its window backend only supports KWin (KDE) and Labwc (XFCE),
# so no fallback install, no /usr/local/bin/pelorus link, no service start and no Nginx route.
# (The Python package itself ships inside the /lsiopy venv of the image and is left untouched.)
if [ "$DESKTOP_ENV" = "sway" ]; then
  echo "--- Verifying Selkies components (Pelorus is skipped for Sway) ---"
  sudo rm -f /usr/local/bin/pelorus
else
  echo "--- Verifying Selkies and Pelorus components ---"
  if [ -f /lsiopy/bin/pelorus ]; then
    echo "[OK] Found /lsiopy/bin/pelorus in extracted image."
  else
    echo "[WARNING] /lsiopy/bin/pelorus not found, installing Pelorus into /lsiopy venv..."
    sudo /lsiopy/bin/pip install git+https://github.com/linuxserver/pelorus.git || true
  fi
  sudo ln -sf /lsiopy/bin/pelorus /usr/local/bin/pelorus
fi
sudo ln -sf /lsiopy/bin/selkies /usr/local/bin/selkies

# 9. Check for missing dynamic library dependencies in /lsiopy
echo "--- Checking dynamic library dependencies in /lsiopy ---"
MISSING_LIBS=$(find /lsiopy -name "*.so*" -exec ldd {} + 2>/dev/null | grep "not found" | sort -u || true)
if [ -n "$MISSING_LIBS" ]; then
  echo "WARNING: Found missing shared libraries for /lsiopy:"
  echo "$MISSING_LIBS"
else
  echo "[OK] All library dependencies in /lsiopy are satisfied."
fi

# 10. Reset capabilities on compositors and disable UDisks2 D-Bus activation (required for unprivileged LXC containers)
for comp in kwin_wayland labwc sway; do
  if command -v "$comp" >/dev/null 2>&1; then
    sudo setcap -r "$(command -v "$comp")" 2>/dev/null || true
    echo "[OK] Removed capabilities from $comp for proper unprivileged LXC operation."
  fi
done
sudo rm -f /usr/share/dbus-1/system-services/org.freedesktop.UDisks2.service

# 11. Prepare configuration directory (and the Pelorus AI agent directory /config/agent, not needed for Sway)
if [ "$DESKTOP_ENV" = "sway" ]; then
  sudo install -d -m 0755 -o "$USER" -g "$(id -gn)" /config
else
  sudo install -d -m 0755 -o "$USER" -g "$(id -gn)" /config /config/agent
fi
sudo chown -R "$USER:$(id -gn)" /config 2>/dev/null || true

# Prepare /tmp/.X11-unix directory for XWayland session
sudo mkdir -p /tmp/.X11-unix
sudo chmod 1777 /tmp/.X11-unix
sudo rm -f /tmp/.X11-unix/X*
sudo tee /etc/tmpfiles.d/x11-unix.conf > /dev/null <<EOF
d /tmp/.X11-unix 1777 root root -
EOF

# 12. Install session scripts to /usr/local/bin
echo "--- Installing Wayland session scripts ---"
sudo cp selkies-startwm-wayland.sh /usr/local/bin/selkies-startwm-wayland.sh
sudo chmod 755 /usr/local/bin/selkies-startwm-wayland.sh
sudo cp kwin-xwayland.py /usr/local/bin/kwin-xwayland.py
sudo chmod 755 /usr/local/bin/kwin-xwayland.py

# 13. Install or update environment file selkies.env
if [ ! -f ~/.config/selkies/selkies.env ]; then
  cp selkies.env ~/.config/selkies/selkies.env
  echo "[OK] Created ~/.config/selkies/selkies.env"
  # In update mode: restore custom settings from backup if present and not overridden
  if [ -f ~/.config/selkies/selkies.env.bak ]; then
    for var in PELORUS_PROVIDER PELORUS_ENDPOINT PELORUS_MODEL PELORUS_API_KEY CUSTOM_PORT CUSTOM_HTTPS_PORT; do
      old_val=$(grep "^${var}=" ~/.config/selkies/selkies.env.bak 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)
      if [ -n "$old_val" ] && [ "$old_val" != '""' ] && [ -z "${!var:-}" ]; then
        sed -i "s|^${var}=.*|${var}=${old_val}|" ~/.config/selkies/selkies.env
      fi
    done
  fi
fi

# Synchronize desktop environment and Pelorus environment settings
sed -i '/^DESKTOP_ENVIRONMENT=/d' ~/.config/selkies/selkies.env
echo "DESKTOP_ENVIRONMENT=$DESKTOP_ENV" >> ~/.config/selkies/selkies.env

# Build a human-readable OS prefix for the window title
if [ "$DISTRO" = "ubuntu" ]; then
  OS_TITLE_PREFIX="Ubuntu-26.04"
else
  OS_TITLE_PREFIX="Debian-13"
fi

if [ "$DESKTOP_ENV" = "xfce" ]; then
  sed -i '/^PELORUS_ENVIRONMENT=/d' ~/.config/selkies/selkies.env
  echo 'PELORUS_ENVIRONMENT="XFCE Desktop (Linux)"' >> ~/.config/selkies/selkies.env
  sed -i "s/^TITLE=.*/TITLE=\"${OS_TITLE_PREFIX} (XFCE)\"/" ~/.config/selkies/selkies.env
elif [ "$DESKTOP_ENV" = "sway" ]; then
  sed -i '/^PELORUS_ENVIRONMENT=/d' ~/.config/selkies/selkies.env
  sed -i "s/^TITLE=.*/TITLE=\"${OS_TITLE_PREFIX} (Sway)\"/" ~/.config/selkies/selkies.env
else
  sed -i '/^PELORUS_ENVIRONMENT=/d' ~/.config/selkies/selkies.env
  echo 'PELORUS_ENVIRONMENT="KDE Plasma Desktop (Linux)"' >> ~/.config/selkies/selkies.env
  sed -i "s/^TITLE=.*/TITLE=\"${OS_TITLE_PREFIX} (KDE)\"/" ~/.config/selkies/selkies.env
fi

# Pelorus on/off. Disabled for Sway (no window backend for it); otherwise on unless the user passed PELORUS=...
if [ "$DESKTOP_ENV" = "sway" ]; then
  if [ "${PELORUS:-}" = "true" ]; then
    warn "Pelorus is not supported with Sway (its window backend only supports KDE and XFCE/Labwc) - disabling it."
  fi
  PELORUS=false
elif [ -z "${PELORUS:-}" ]; then
  PELORUS=true
fi
export PELORUS
sed -i '/^PELORUS=/d' ~/.config/selkies/selkies.env
echo "PELORUS=$PELORUS" >> ~/.config/selkies/selkies.env
echo "[INFO] PELORUS=$PELORUS (desktop: $DESKTOP_ENV)"

# Ensure critical ports and settings are present in existing configuration
for cfg_line in \
    "CUSTOM_WS_PORT=8082" \
    "SELKIES_PORT=8082" \
    "SELKIES_COMPUTER_USE_BIND=5000" \
    "SELKIES_APP_WAYLAND_DISPLAY=wayland-0" \
    "SELKIES_COMMAND_ENABLED=true" \
    "SELKIES_ENABLE_DUAL_MODE=false"; do
  cfg_key="${cfg_line%%=*}"
  if ! grep -q "^${cfg_key}=" ~/.config/selkies/selkies.env; then
    echo "$cfg_line" >> ~/.config/selkies/selkies.env
  fi
done

# Generate PIXELFLUX_CU_TOKEN if missing or empty (required by Pixelflux 2.2+ and Pelorus 0.2.4+)
current_cu_token=$(grep "^PIXELFLUX_CU_TOKEN=" ~/.config/selkies/selkies.env 2>/dev/null | cut -d= -f2- | tr -d ' "\r' || true)
if [ -z "$current_cu_token" ]; then
  cu_token="$(openssl rand -hex 32)"
  sed -i '/^PIXELFLUX_CU_TOKEN=/d' ~/.config/selkies/selkies.env
  echo "PIXELFLUX_CU_TOKEN=$cu_token" >> ~/.config/selkies/selkies.env
  echo "[OK] Generated PIXELFLUX_CU_TOKEN in ~/.config/selkies/selkies.env"
fi
echo "[INFO] Verified and synchronized ~/.config/selkies/selkies.env configuration."

# 14. Configure PulseAudio services (null-sinks)
echo "--- Configuring PulseAudio ---"
sudo mkdir -p /etc/pulse/default.pa.d
sudo tee /etc/pulse/default.pa.d/selkies.pa > /dev/null <<EOF
load-module module-null-sink sink_name="output" sink_properties=device.description="output"
load-module module-null-sink sink_name="input" sink_properties=device.description="input"
set-default-sink output
set-default-source input.monitor
EOF

# 15. Disable PipeWire in favor of PulseAudio
# --global works without an active session and applies to all users (mask in /etc/systemd/user)
PW_UNITS=(pipewire.service pipewire.socket wireplumber.service pipewire-pulse.service pipewire-pulse.socket)
sudo systemctl --global mask "${PW_UNITS[@]}" 2>/dev/null || warn "Failed to mask PipeWire (--global)"
# Stop anything already running in the current session
systemctl --user stop "${PW_UNITS[@]}" 2>/dev/null || true
echo "[OK] PipeWire masked - PulseAudio remains the only sound server."

# 16. Run Nginx and Selkies initialization scripts
echo "--- Initializing Nginx and Selkies configuration ---"
export CUSTOM_WS_PORT="${CUSTOM_WS_PORT:-8082}"
sudo --preserve-env=PASSWORD,CUSTOM_PORT,CUSTOM_HTTPS_PORT,CUSTOM_WS_PORT,SUBFOLDER,DASHBOARD,DISABLE_IPV6,SELKIES_FILE_TRANSFERS,HARDEN_DESKTOP,PELORUS,SELKIES_ROOTFS,SELKIES_IMAGE,SELKIES_TAG bash 01-init-nginx.sh
sudo bash 02-init-selkies-config.sh

# 17. Remove temporary udocker container and image
udocker rm selkies_tmp 2>/dev/null || true
udocker rmi "$SELKIES_IMAGE" 2>/dev/null || true

# 17b. Optional Google Chrome installation via install-chrome.sh
if [ "${INSTALL_CHROME:-no}" = "yes" ]; then
  echo "--- Installing Google Chrome via install-chrome.sh ---"
  bash "$SCRIPT_DIR/install-chrome.sh"
fi

fi  # end of !SERVICES_ONLY block

# 18. Install systemd user units
echo "--- Installing systemd units for user session ---"
mkdir -p ~/.config/systemd/user

# Remove legacy xvfb service if previously active
if systemctl --user is-active --quiet xvfb 2>/dev/null || systemctl --user is-enabled --quiet xvfb 2>/dev/null; then
  systemctl --user disable --now xvfb 2>/dev/null || true
fi
rm -f ~/.config/systemd/user/xvfb.service

cp selkies.service desktop.service ~/.config/systemd/user/

# 19. Enable and start systemd user services
# Re-verify the session right before using systemctl --user
ensure_user_session hard
sudo loginctl enable-linger "$USER"

# PipeWire (in case of --services-only mode) - global mask
sudo systemctl --global mask pipewire.service pipewire.socket wireplumber.service \
  pipewire-pulse.service pipewire-pulse.socket 2>/dev/null || true

systemctl --user daemon-reexec
systemctl --user daemon-reload
systemctl --user enable --now pulseaudio selkies desktop

echo "=== Installation completed successfully! ($(date -Is)) ==="
echo "Installation log saved to: $INSTALL_LOG"
echo "Access URLs:"
echo "  Desktop: https://<container_ip>:3001/ or http://<container_ip>:3000/"
[ "${PELORUS:-true}" = "true" ] && echo "  Pelorus AI: https://<container_ip>:3001/pelorus/"
echo
echo "Check services:  systemctl --user status pulseaudio selkies desktop"
