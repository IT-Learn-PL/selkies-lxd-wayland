# selkies-lxd-wayland (Wayland + Pelorus)

High-performance installation and setup scripts for running **Selkies** WebRTC desktop streaming in native **Wayland** mode with the **Pelorus** AI navigator inside **LXC / LXD / Proxmox VE** containers.

Supports **KDE Plasma**, **XFCE**, and **Sway**, running under native `systemd --user` session management without requiring Docker or nested container engines.

> [!IMPORTANT]
> **Supported operating systems only:**
> - **Debian 13 (Trixie)** — uses `lsiobase/selkies:debiantrixie-*` image from LinuxServer.io
> - **Ubuntu 26.04 LTS (Resolute Raccoon)** — uses `lsiobase/selkies:ubunturesolute-*` image from LinuxServer.io
>
> The installer detects the OS automatically and aborts with a clear error on any other distribution or version.

---

## Key Features

- **Native Wayland Streaming**: Powered by Pixelflux (Smithay compositor) listening on socket `wayland-1` via WebRTC and HTTPS.
- **Nested Compositors**:
  - **KDE Plasma**: Uses **KWin Wayland** nested client on `wayland-1`, hosting `wayland-0` and XWayland.
  - **XFCE**: Uses **Labwc** (wlroots-based stacking compositor) nested client on `wayland-1`, hosting the application socket and XWayland.
  - **Sway**: Uses **Sway** (wlroots-based i3-compatible tiling compositor) nested client on `wayland-1`, hosting the application socket and XWayland. Ships with a **Waybar** top bar and a clickable **Menu** launcher (`wofi`).
  - The application socket is normally `wayland-0`. wlroots compositors (Sway, Labwc) pick the first free `wayland-N` name themselves, so the session script detects the real name and, if it differs, links `wayland-0` to it (see [Nested compositor socket](#nested-compositor-socket)).
- **Pelorus AI Navigation Agent** (KDE Plasma and XFCE only): Integrated FastAPI agent (port 5100, reverse-proxied at `/pelorus/`), reading window states and accessibility trees via AT-SPI2 / D-Bus and executing actions through Pixelflux's token-authenticated Computer Use API (port 5000). Pelorus lists and closes windows through KWin (D-Bus) or Labwc (IPC socket) and has no backend for Sway, so **it is not installed or started when Sway is selected** (see [Sway desktop notes](#sway-desktop-notes)).
- **Proxmox & LXD Native**: Runs as an unprivileged or privileged LXC container; handles `systemd --user` sessions automatically even when initiated via `pct enter` or `su`.
- **Hardware GPU Acceleration & Video Decoding**:
  - Automatic `/dev/dri` device verification (`video` and `render` group IDs).
  - Intel VA-API (`intel-media-va-driver-non-free`) and AMD Mesa drivers for hardware video acceleration.
  - Software rendering fallback (`KWIN_COMPOSE=Q` with multi-threaded `llvmpipe`) when no GPU is attached.
- **Google Chrome Integration**: Optional automated installation with native Wayland flags, basic password store, and VA-API hardware decoding enabled.
- **Persistent User Applications (`proot-apps`)**: Pre-configured support for user-level rootless applications, accessible directly from the Selkies web sidebar ("Apps" menu).
- **Audio Redirection**: Clean PulseAudio architecture with virtual null sinks (`output` and `input`), while PipeWire is automatically masked to prevent sound server conflicts.
- **Gamepad / Joystick Passthrough**: Ready-to-use host script to pass gamepad devices into the container.

---

## Architecture Overview

```
                        +---------------------------------------+
                        |           Web Browser Client          |
                        | (Selkies WebRTC / Nginx HTTPS :3001)  |
                        +-------------------+-------------------+
                                            |
                                            v
+---------------------------------------------------------------------------------------+
| LXC Container                                                                         |
|                                                                                       |
|   +-------------------------------------------------------------------------------+   |
|   | Nginx Reverse Proxy (Port 3000 HTTP / 3001 HTTPS)                             |   |
|   |  - /           -> Selkies Web Client & WebSockets (:8082)                     |   |
|   |  - /pelorus/   -> Pelorus AI Interface (:5100)                                |   |
|   +---------------------------------------+---------------------------------------+   |
|                                           |                                           |
|   +---------------------------------------v---------------------------------------+   |
|   | Selkies Streaming Daemon (Pixelflux / Smithay)                                |   |
|   |  - WebRTC / WebSocket video & audio streamer (:8082)                          |   |
|   |  - Provides root Wayland compositor socket: wayland-1                         |   |
|   |  - Computer Use (CU) API (:5000) protected by PIXELFLUX_CU_TOKEN              |   |
|   +---------------------------------------+---------------------------------------+   |
|                                           | (Wayland socket: wayland-1)               |
|   +---------------------------------------v---------------------------------------+   |
|   | Nested Desktop Compositor (wayland-0 or symlink)                              |   |
|   |  - KDE: KWin Wayland (kwin-xwayland.py)                                       |   |
|   |  - XFCE: Labwc (wlroots)                                                      |   |
|   |  - Sway: Sway (wlroots) + Waybar / wofi launcher                              |   |
|   |  - XWayland compatibility layer for legacy X11 applications                   |   |
|   +-------------------+-----------------------------------+-----------------------+   |
|                       |                                   |                           |
|   +-------------------v--------------------+  +-----------v-----------------------+   |
|   | Desktop Applications & User Session    |  | Pelorus AI Agent (:5100)          |   |
|   |  - KDE Plasma (plasmashell) / XFCE4    |  |  - Accessibility Tree (AT-SPI2)   |   |
|   |  - Google Chrome / Firefox / foot      |  |  - Dispatches actions to :5000    |   |
|   |  - proot-apps (user space packages)    |  |  - LLM: Ollama / OpenAI / Gemini  |   |
|   +----------------------------------------+  +-----------------------------------+   |
|                                                                                       |
|   +-------------------------------------------------------------------------------+   |
|   | Audio Daemon (PulseAudio)                                                     |   |
|   |  - Virtual null-sinks: output (sink) and input (source)                       |   |
|   +-------------------------------------------------------------------------------+   |
+---------------------------------------------------------------------------------------+
```

---

## Requirements & Prerequisites

### 1. Supported Operating Systems & Selkies Images

The installer detects the OS automatically from `/etc/os-release` and selects the matching dedicated LinuxServer.io Selkies base image. Only the following combinations are supported:

| OS | Selkies Image |
|---|---|
| **Debian 13 (Trixie)** | `lsiobase/selkies:debiantrixie-60ce2ea6-ls152` |
| **Ubuntu 26.04 LTS (Resolute Raccoon)** | `lsiobase/selkies:ubunturesolute-87420d8d-ls41` |

> [!NOTE]
> Any other OS version causes an immediate error with a list of supported systems. You can override the auto-detected image by passing `SELKIES_IMAGE=<tag>` as an environment variable.

### 2. Supported Environments
- **Host**: Proxmox VE, LXD, or vanilla LXC.
- **CPU Architectures**: `x86_64` (AMD64) or `aarch64` (ARM64). *Note: Google Chrome installation is available on `x86_64` only.*

### 3. OS-Specific Package Notes

#### Debian 13 (Trixie)
- Enables the `non-free` APT component for `intel-media-va-driver-non-free` (Intel VA-API).
- Uses `firefox-esr` from the main Debian repository.

#### Ubuntu 26.04 LTS (Resolute Raccoon)
- Enables the `universe` and `restricted` APT components for GPU and VA-API drivers.
- Intel VA-API uses `intel-media-va-driver` (no `-non-free` suffix; available in `restricted`).
- For XFCE installations, adds the **Mozilla Team PPA** (`ppa:mozillateam/ppa`) with APT pin priority 1001 to install a proper Firefox `.deb` instead of the default Snap redirect.
- `plasma-welcome` exclusion marker is omitted (package does not exist in Ubuntu 26.04).

### 4. Proxmox VE Container Configuration
For Proxmox VE containers, ensure `nesting` and `keyctl` features are enabled (required for `systemd --user` session bus and lingering):

```bash
pct set <CTID> --features nesting=1,keyctl=1
pct reboot <CTID>
```

### 5. GPU Acceleration (Optional)

By default, the installer configures software rendering (`KWIN_COMPOSE=Q`) with multi-threaded `llvmpipe` / `pixman`, ensuring smooth execution on CPU-only hosts. Software rendering at large resolutions (e.g. a full-size browser window) can make the cursor feel laggy; a GPU render node or a smaller resolution helps.

If GPU passthrough is desired:
- **LXD**:
  ```bash
  lxc config device add <container_name> gpu gpu
  ```
- **Proxmox VE**: Map the DRM devices into the container with the `dev<N>` option in `/etc/pve/lxc/<CTID>.conf`, using the group IDs of `render` and `video` **inside the container** (`getent group render video`), then restart the container:
  ```
  dev0: /dev/dri/renderD128,gid=<render gid>
  dev1: /dev/dri/card0,gid=<video gid>
  ```
- The installer automatically validates `/dev/dri` permissions and GID mapping during installation.
- Switch to GPU rendering by setting `KWIN_COMPOSE=O2` in `~/.config/selkies/selkies.env`, then `systemctl --user restart selkies desktop`. For Sway and Labwc this only means that `WLR_RENDERER=pixman` is no longer forced; wlroots then selects the GPU renderer itself. You can pin the device with `WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`.
- Verify that the compositor uses the GPU (Sway example):
  ```bash
  ls -l /proc/$(pgrep -x sway)/fd | grep dri
  ```

### Nested compositor socket

Selkies (Pixelflux) owns `wayland-1`. The desktop compositor runs nested on it and creates a socket of its own, which Selkies uses to route input and clipboard (`SELKIES_APP_WAYLAND_DISPLAY`, default `wayland-0`).

KWin can be given a fixed socket name, but wlroots compositors (Sway, Labwc) take the first free `wayland-N`, which is not always `wayland-0`. `selkies-startwm-wayland.sh` therefore:

1. waits until `wayland-1` actually accepts connections (a stale socket file can remain while Selkies restarts),
2. snapshots the existing sockets before starting the compositor and detects the new one afterwards,
3. exports the real name as `WAYLAND_DISPLAY` for the session, and
4. if the name differs from `SELKIES_APP_WAYLAND_DISPLAY`, creates a symlink `wayland-0 -> wayland-N` (removed again when the session ends).

You will see this in `journalctl --user -u desktop`, e.g. `Nested compositor listens on wayland-2 (expected wayland-0); linking wayland-0 -> wayland-2`, and `ls -l "$XDG_RUNTIME_DIR"/wayland-*` shows the symlink.

### Sway desktop notes

- Sway is a tiling compositor and has no start menu by design. The generated setup provides a **Waybar** top bar with a **Menu** button (`wofi --show drun`); `Super+D` opens the same launcher and `Super+Enter` opens `foot`. If your browser or OS captures the `Super` key, use the Menu button or change `set $mod Mod4` to `Mod1` (Alt) in `~/.config/sway/config`.
- `~/.config/sway/config`, `~/.config/waybar/config.jsonc` and `~/.config/waybar/style.css` are only created when they do not exist yet, so your own changes are never overwritten. To regenerate the defaults, move them aside and restart the session:
  ```bash
  mv ~/.config/sway/config ~/.config/sway/config.bak
  mv ~/.config/waybar ~/.config/waybar.bak
  systemctl --user restart desktop
  ```
- If the `sway-backgrounds` wallpaper is not installed, a solid background colour is used instead.
- **Pelorus is not available with Sway.** Its window backend (`desktop.py`) only knows KWin (via `qdbus6`) and Labwc (via `labwc.sock`), so on Sway `/api/windows` fails. With `DESKTOP_ENVIRONMENT=sway` the installer therefore skips Pelorus completely: no `/usr/local/bin/pelorus` link, no `/config/agent`, `PELORUS=false` in `selkies.env`, no `/pelorus/` route in Nginx, and the session script does not start it. (The Python package itself ships inside the `/lsiopy` virtualenv of the Selkies image and stays there unused.) The Pixelflux Computer Use API on port 5000 is unaffected.
- Switching an existing Sway installation: re-run `bash setup.sh sway` (or set `PELORUS=false` in `~/.config/selkies/selkies.env`, re-run `bash 01-init-nginx.sh` with `PELORUS=false` and `systemctl --user restart desktop`).
- Switching from Sway back to KDE/XFCE: re-run `setup.sh` for that desktop; `PELORUS` is set to `true` again unless you pass `PELORUS=false` yourself.

---

## Installation

### Quick Start

Inside the LXC container as a regular user with `sudo` permissions (or as root; `setup.sh` will automatically switch to the designated user):

```bash
git clone https://github.com/IT-Learn-PL/selkies-lxd-wayland.git
cd selkies-lxd-wayland
bash setup.sh
```

During interactive execution, the installer detects any already installed desktop environment and prompts you for:
1. **Desktop Environment & Installation Mode**:
   - `1` for KDE Plasma full install (default)
   - `2` for XFCE full install
   - `3` for Sway full install
   - `4` for Selkies only using existing KDE Plasma (skips desktop packages)
   - `5` for Selkies only using existing XFCE (skips desktop packages)
   - `6` for Selkies only using existing Sway (skips desktop packages)
2. **Google Chrome**: Option to install Google Chrome with Wayland & VA-API acceleration (x86_64 only).

All installation output is mirrored in real time to `/tmp/selkies-lxd-wayland-install.log`.

---

### Command-Line Arguments & Non-Interactive Usage

You can automate installation or select options via command-line arguments:

```bash
# Install KDE Plasma with Google Chrome
bash setup.sh kde --with-chrome

# Install XFCE without Google Chrome
bash setup.sh xfce --no-chrome

# Install Sway (Wayland tiling compositor)
bash setup.sh sway

# Install Selkies only for an already installed desktop (skips DE package downloads)
bash setup.sh kde --selkies-only
bash setup.sh sway --selkies-only
# or auto-detect installed desktop:
bash setup.sh --selkies-only

# Install only required system packages and dependencies (skips Selkies & services)
bash setup.sh kde --packages-only

# Repair or reconfigure only systemd --user services without reinstalling packages
bash setup.sh --services-only

# Update existing installation (automatically cleans previous Selkies components)
bash setup.sh

# Reconfigure or install without cleaning previous components
bash setup.sh --no-cleanup
```

#### Available CLI Arguments:
| Argument | Description |
|---|---|
| `kde` / `xfce` / `sway` | Selects target desktop environment (`kde` = KDE Plasma 6, `xfce` = XFCE 4 with Labwc, `sway` = Sway tiling compositor). |
| `--with-chrome` | Automatically installs Google Chrome (x86_64 only) with hardware decoding. |
| `--no-chrome` | Skips Google Chrome installation prompt. |
| `--selkies-only` | Installs Selkies streaming components and services only, skipping desktop environment packages (for systems with an already installed desktop). |
| `--packages-only` | Installs only required system packages and dependencies, then exits (skips Selkies image extraction, services, and configuration). |
| `--services-only` | Skips package downloads and only writes service files and configuration. |
| `--fix-session` | Diagnoses and repairs the `systemd --user` session bus, then exits. |
| `--no-cleanup` | Skips automatic removal of previous Selkies components during reinstallation or update. |

#### Supported Environment Variables:
| Variable | Default | Description |
|---|---|---|
| `DESKTOP_ENV` | `kde` | Target desktop environment (`kde`, `xfce`, or `sway`). |
| `INSTALL_CHROME` | `no` | Install Google Chrome (`yes` or `no`). |
| `SELKIES_ONLY` | `0` | Installs Selkies only without installing desktop environment packages (equivalent to `--selkies-only`). |
| `PACKAGES_ONLY` | `0` | Installs only system packages and dependencies (equivalent to `--packages-only`). |
| `SERVICES_ONLY` | `0` | Configures only services and environment files, skipping package installations (equivalent to `--services-only`). |
| `SKIP_CLEANUP` | `0` | Skips automatic removal of previous Selkies components during update (equivalent to `--no-cleanup`). |
| `PASSWORD` | *(empty)* | Sets HTTP Basic Authentication password for Nginx web access. |
| `SETUP_USER` | *(auto)* | Target username when script is executed as `root` (e.g. from `pct enter`). |
| `CUSTOM_PORT` | `3000` | Nginx HTTP port. |
| `CUSTOM_HTTPS_PORT` | `3001` | Nginx HTTPS port. |
| `CUSTOM_WS_PORT` | `8082` | Selkies backend WebSocket port. |
| `SUBFOLDER` | `/` | Web application root subfolder. |
| `DISABLE_IPV6` | `true` | Disables IPv6 listener in Nginx. |
| `PELORUS` | `true` | Enables Pelorus AI navigation server. Forced to `false` for Sway (unsupported). |

---

## Google Chrome Installer (`install-chrome.sh`)

Google Chrome can be installed either via `setup.sh --with-chrome` or standalone using `install-chrome.sh`:

```bash
bash install-chrome.sh
```

### Highlights:
- Configures Chrome policies at `/etc/opt/chrome/policies/managed/default.json` and flag overrides at `~/.config/chrome-flags.conf`.
- Enables native Wayland windowing (`--ozone-platform-hint=auto` / `--ozone-platform=wayland`).
- Enables VA-API hardware video decoding (`--enable-features=VaapiVideoDecodeLinuxGL,VaapiVideoDecoder`).
- Sets `--password-store=basic` to prevent keyring prompts on headless/nested sessions.
- Use `bash install-chrome.sh --flags-only` to refresh configuration files without reinstalling apt packages.

---

## Application Management with `proot-apps`

The environment comes pre-configured with [proot-apps](https://github.com/linuxserver/proot-apps), enabling persistent rootless software installation:

1. **Selkies Web Sidebar**:
   - Applications installed via `proot-apps` appear under the **Apps** menu in the Selkies web interface.
   - Powered by `selkies-proot` integration in `/usr/local/bin/selkies-proot`.
2. **Command-Line Usage**:
   ```bash
   # List available applications
   proot-apps list

   # Install an application (e.g., FileZilla, Blender, LibreOffice)
   proot-apps install filezilla

   # Launch an installed application
   proot-apps run filezilla
   ```

---

## Configuration (`~/.config/selkies/selkies.env`)

User configuration is managed in `~/.config/selkies/selkies.env`. Changes take effect after restarting user services (`systemctl --user restart selkies desktop`).

### Core Variables

| Section | Variable | Default | Description |
|---|---|---|---|
| **Compositor** | `DESKTOP_ENVIRONMENT` | `kde` | Desktop session: `kde` (KDE Plasma), `xfce` (XFCE + Labwc) or `sway` (Sway + Waybar). |
| | `KWIN_COMPOSE` | `Q` | Compositor backend: `Q` (software rendering via QPainter/pixman) or `O2` (OpenGL for GPU passthrough). For Sway/Labwc, `Q` sets `WLR_RENDERER=pixman`. |
| | `PIXELFLUX_WAYLAND` | `true` | Enables Smithay Wayland compositor inside Pixelflux. |
| | `WAYLAND_DISPLAY` | `wayland-1` | Socket hosted by Pixelflux for nested compositor clients. |
| | `SELKIES_APP_WAYLAND_DISPLAY` | `wayland-0` | Socket of the nested compositor (KWin / Labwc / Sway) used by Selkies for input and clipboard. If the compositor picks another name, the session script symlinks it to this one. |
| **Streaming** | `CUSTOM_WS_PORT` / `SELKIES_PORT` | `8082` | WebSocket port used by Selkies daemon and Nginx proxy. |
| | `SELKIES_ENCODER` | `h264enc` | Video encoder (`h264enc`, `h265enc`, `vp8enc`, `vp9enc`, `av1enc`, `jpeg`). |
| | `SELKIES_FRAMERATE` | `60` | Target stream frame rate. |
| | `SELKIES_COMMAND_ENABLED` | `true` | Enables WebSocket commands required for Selkies 2.2+ sidebar launcher. |
| **Pelorus AI** | `PELORUS` | `true` | Activates Pelorus AI navigator and UI. KDE and XFCE only; `setup.sh` sets it to `false` for Sway. |
| | `PELORUS_PORT` | `5100` | Port for Pelorus FastAPI server. |
| | `PIXELFLUX_CU` | `5000` | Pixelflux Computer Use API port. |
| | `PIXELFLUX_CU_TOKEN` | *(auto-generated)* | 32-byte secret Bearer token protecting the Computer Use API. |
| | `PELORUS_PROVIDER` | `ollama` | Default LLM provider (`ollama`, OpenAI-compatible, or `gemini`). |
| | `PELORUS_ENDPOINT` | `http://localhost:11434` | Endpoint URL for the LLM provider. |
| | `PELORUS_MODEL` | `gemma4:12b` | Model name. |
| | `PELORUS_API_KEY` | `""` | Optional LLM API key. |

Pelorus agent runtime settings can also be modified in `/config/agent/config.toml` or via the web UI at `/pelorus/`.

---

## Security Notice

> [!WARNING]
> - The **Pelorus** agent listens on port `5100` without upstream authentication.
> - The **Pixelflux Computer Use API** listens on port `5000` and allows simulated mouse and keyboard input and screen scraping. It is guarded by `PIXELFLUX_CU_TOKEN`.
> - **Do not expose ports 5000 or 5100 to public networks.**

### Recommended Security Practices:
1. Access the desktop and Pelorus strictly through Nginx over HTTPS (`https://<container_ip>:3001/` and `https://<container_ip>:3001/pelorus/`).
2. Secure web access with HTTP Basic Authentication during setup:
   ```bash
   PASSWORD="YourStrongPassword" bash setup.sh
   ```
3. Secure LLM provider credentials stored in `/config/agent/config.toml` by maintaining strict file permissions (`chmod 600`).

---

## Gamepad / Joystick Passthrough

To use physical controllers (Xbox, DualShock, generic USB joysticks) inside the container:

Run the included helper script on the **LXD / Proxmox host** before starting your session:

```bash
bash 00-lxd-host-joystick.sh <container_name>
```

This maps `/dev/input/js0-3` and `/dev/input/event1000-1003` into the container with appropriate permissions.

---

## Access URLs

| Interface | URL |
|---|---|
| **Selkies Desktop (HTTPS)** | `https://<container_ip>:3001/` |
| **Selkies Desktop (HTTP)** | `http://<container_ip>:3000/` |
| **Pelorus AI Navigator** | `https://<container_ip>:3001/pelorus/` |
| **Pelorus FastAPI Documentation** | `https://<container_ip>:3001/pelorus/docs` |

---

## Verification & Troubleshooting

### Service Verification Commands

```bash
# 1. Check status of systemd user services
systemctl --user status selkies desktop pulseaudio

# 2. Check Nginx status
sudo systemctl status nginx

# 3. View Selkies streaming logs
journalctl --user -u selkies -n 50 --no-pager

# 4. View desktop and Pelorus logs
journalctl --user -u desktop -n 80 --no-pager

# 5. Check Wayland sockets (wayland-1 and wayland-0 must exist; wayland-0 may be a symlink to the compositor's real socket)
ls -l "$XDG_RUNTIME_DIR"/wayland-*

# 6. Verify listening network ports (:3000, :3001, :5000, :5100, :8082)
ss -ltnp | grep -E ':(3000|3001|5000|5100|8082)\b'

# 7. Test Nginx HTTPS endpoint
curl -skI https://localhost:3001/ | head -n 5

# 8. Test Pelorus accessibility tree window detection
curl -s http://127.0.0.1:5100/api/windows
```

For a comprehensive cheatsheet of troubleshooting steps and commands, see [troubleshoot.txt](troubleshoot.txt).

### Common Issues & Solutions

- **"Failed to start a systemd --user session" (when entering via `pct enter`)**:
  - Run `bash setup.sh --fix-session`.
  - Ensure the Proxmox container has nesting enabled: `pct set <CTID> --features nesting=1,keyctl=1`.
- **Black screen in browser**:
  - For containers without GPU passthrough, verify `KWIN_COMPOSE=Q` in `~/.config/selkies/selkies.env`.
  - If changing `KWIN_COMPOSE`, remove cached settings (`rm -f ~/.config/kwinrc`) and restart the desktop: `systemctl --user restart desktop`.
- **Selkies log is full of `wayland-0: No such file or directory` (FakeInput)**:
  - The nested compositor is not reachable under `SELKIES_APP_WAYLAND_DISPLAY`. Check `ls -l "$XDG_RUNTIME_DIR"/wayland-*` and make sure `/usr/local/bin/selkies-startwm-wayland.sh` is the current version (re-run `bash setup.sh --services-only` or copy it manually) and restart: `systemctl --user restart selkies desktop`.
- **`selkies.env: syntax error near unexpected token '('`**:
  - Older installers wrote `TITLE=Debian-13 (Sway)` without quotes. Fix with `sed -i 's/^TITLE=.*/TITLE="Debian-13 (Sway)"/' ~/.config/selkies/selkies.env`.
- **Sway starts with `Could not connect to remote display: Connection refused`**:
  - Happens when the session restarts while the old `wayland-1` socket file still exists. The current session script waits for a live socket; the service also retries automatically (`Restart=always`).
- **Laggy cursor / low frame rate with Sway or Labwc**:
  - Software rendering at a large resolution is CPU-bound. Check `top` while moving the cursor, pass a GPU through (see [GPU Acceleration](#5-gpu-acceleration-optional)) or try `SELKIES_ENABLE_RESIZE=false` and `SELKIES_FRAMERATE=30` to compare.
- **Sway shows only a black screen and a bar**:
  - This is normal for an empty workspace without a wallpaper. Open a terminal (`Super+Enter`) or the Menu button.
- **No `/pelorus/` page with Sway**: expected, Pelorus is not installed for Sway (see above).
- **`FileNotFoundError: 'qdbus6'` in `/tmp/pelorus.log`**: Pelorus was started on a desktop other than KDE/Labwc. Set `PELORUS=false` (this is done automatically for Sway).
- **502 Bad Gateway under `/pelorus/`**:
  - Check if the Pelorus process is running: `pgrep -a pelorus` or inspect `/tmp/pelorus.log`.
  - Verify that `PIXELFLUX_CU=5000` is active and `selkies.service` is running.
- **Missing Audio in Browser**:
  - Confirm PulseAudio null sinks exist: `pactl list short sinks` (should show `output`).
  - Make sure PipeWire is masked: `systemctl --user status pipewire` should report masked or inactive.

---

## License & Acknowledgements

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See the [LICENSE](LICENSE) file for full details.

### Acknowledgements

This project builds upon, adapts, and integrates open-source components developed by the [LinuxServer.io](https://www.linuxserver.io/) team:
- **Pelorus** ([docker-pelorus](https://github.com/linuxserver/docker-pelorus))
- **Selkies Base Image** ([docker-baseimage-selkies](https://github.com/linuxserver/docker-baseimage-selkies))
- **proot-apps** ([proot-apps](https://github.com/linuxserver/proot-apps))

Special thanks to LinuxServer.io and the open-source community for their foundational work.
