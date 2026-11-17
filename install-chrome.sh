#!/bin/bash
set -eo pipefail

# ==============================================================================
# Google Chrome installer for selkies-lxd-wayland
# Installs Chrome with native Wayland and GPU (VA-API) video decoding flags.
# Safe to re-run; does not touch Selkies, Nginx or any systemd services.
#
# Usage:
#   bash install-chrome.sh [--flags-only]
#
#   --flags-only   only (re)write the Chrome flag files, skip all apt work
#
# Variables:
#   CHROME_EXTRA_FLAGS="..."   extra flags appended to the defaults
#   SETUP_USER=<user>          target user when started as root
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

FLAGS_ONLY=0
ORIG_ARGS=("$@")
for arg in "$@"; do
  case "$arg" in
    --flags-only) FLAGS_ONLY=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log()  { echo "[chrome] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Started as root (e.g. `pct enter`): re-run as a regular user via a login shell
if [ "$(id -u)" -eq 0 ]; then
  target="${SETUP_USER:-}"
  if [ -z "$target" ]; then
    mapfile -t users < <(getent passwd | awk -F: '$3>=1000 && $3<60000 && $7 !~ /nologin|false/ {print $1}')
    if [ "${#users[@]}" -eq 1 ]; then
      target="${users[0]}"
    else
      die "Do not run as root. Run as a regular user with sudo, or: SETUP_USER=<username> bash $0
       Available users: ${users[*]:-none}"
    fi
  fi
  id "$target" >/dev/null 2>&1 || die "User '$target' does not exist."
  chmod a+rx "$SCRIPT_DIR" 2>/dev/null || true
  chmod a+rx "$SCRIPT_DIR/$(basename "$0")" 2>/dev/null || true
  envs=""
  [ -n "${CHROME_EXTRA_FLAGS:-}" ] && envs=" $(printf 'CHROME_EXTRA_FLAGS=%q' "$CHROME_EXTRA_FLAGS")"
  args=""
  [ "${#ORIG_ARGS[@]}" -gt 0 ] && args="$(printf ' %q' "${ORIG_ARGS[@]}")"
  log "Switching to user '$target'..."
  exec runuser -l "$target" -c "env${envs} bash $(printf '%q' "$SCRIPT_DIR/$(basename "$0")")${args}"
fi

: "${USER:=$(id -un)}"
export USER

# ---------- Preconditions ----------
ARCH="$(uname -m)"
if [ "$ARCH" != "x86_64" ]; then
  die "Google Chrome has no Linux build for '$ARCH' (x86_64 only)."
fi

if [ "$FLAGS_ONLY" != "1" ]; then
  command -v sudo >/dev/null 2>&1 || die "'sudo' not found. As root: apt install sudo && usermod -aG sudo $USER"
  sudo -v || die "User '$USER' does not have sudo privileges."

  # ---------- Packages ----------
  log "Installing VA-API drivers and prerequisites..."
  sudo apt update
  # Mesa VA-API (AMD) and Intel media driver (Gen8+); vainfo for diagnostics
  sudo DEBIAN_FRONTEND=noninteractive apt install -yq \
    curl gnupg ca-certificates vainfo libva2 libva-drm2 libva-wayland2 \
    mesa-va-drivers intel-media-va-driver \
    || warn "Some VA-API packages failed to install - GPU video decoding may be unavailable."

  # ---------- Google APT repository ----------
  log "Configuring the Google Chrome APT repository..."
  sudo install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null

  log "Installing/upgrading google-chrome-stable..."
  sudo apt update
  sudo DEBIAN_FRONTEND=noninteractive apt install -yq google-chrome-stable
  sudo apt clean

  # Access to /dev/dri render nodes (relevant only with GPU passthrough)
  if getent group render >/dev/null 2>&1; then
    sudo usermod -aG render "$USER"
  fi
  sudo usermod -aG video "$USER"
fi

[ -x /usr/bin/google-chrome-stable ] || die "google-chrome-stable is not installed (run without --flags-only first)."

# ---------- Flags ----------
CHROME_FLAGS="--ozone-platform=wayland --password-store=basic"
CHROME_FLAGS+=" --enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiIgnoreDriverChecks,VaapiVideoDecoder,WaylandWindowDecorations"
CHROME_FLAGS+=" --enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist"
[ -n "${CHROME_EXTRA_FLAGS:-}" ] && CHROME_FLAGS+=" ${CHROME_EXTRA_FLAGS}"

# 1) Flags read by Chrome's wrapper script (covers launches from a terminal)
mkdir -p ~/.config
{
  echo "# Managed by selkies-lxd-wayland install-chrome.sh"
  for flag in $CHROME_FLAGS; do echo "$flag"; done
} > ~/.config/chrome-flags.conf
log "Wrote ~/.config/chrome-flags.conf"

# 2) User-level launcher override (covers the application menu / desktop icons).
#    Regenerated from the system launcher on every run so Chrome updates are picked up.
mkdir -p ~/.local/share/applications
if [ -f /usr/share/applications/google-chrome.desktop ]; then
  sed "s|^Exec=/usr/bin/google-chrome-stable|Exec=/usr/bin/google-chrome-stable ${CHROME_FLAGS}|" \
    /usr/share/applications/google-chrome.desktop > ~/.local/share/applications/google-chrome.desktop
  log "Wrote ~/.local/share/applications/google-chrome.desktop"
else
  warn "System launcher /usr/share/applications/google-chrome.desktop not found - skipped."
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database ~/.local/share/applications 2>/dev/null || true

# ---------- GPU check ----------
if ls /dev/dri/renderD* >/dev/null 2>&1; then
  node="$(ls /dev/dri/renderD* | head -n1)"
  log "GPU render node found: $node"
  if command -v vainfo >/dev/null 2>&1; then
    vainfo --display drm --device "$node" 2>&1 | grep -E 'Driver version|VAProfile(H264|HEVC|VP9|AV1)' | head -n 8 || true
  fi
else
  warn "No /dev/dri/renderD* in this container - Chrome will use software video decoding until the GPU is passed through
       (LXD: lxc config device add <container> gpu gpu)."
fi

echo
echo "=== Google Chrome is ready ==="
echo "Launch it from the desktop menu, or: google-chrome-stable"
echo "Verify in Chrome:  chrome://gpu  ->  Video Decode: Hardware accelerated, Ozone platform: wayland"
echo "Note: group changes (render/video) apply after the next login; restart the session with:"
echo "  systemctl --user restart desktop"
