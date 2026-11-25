# selkies-lxd-wayland (Wayland + Pelorus)

High-performance installation and setup scripts for running **Selkies** WebRTC desktop streaming in native **Wayland** mode with the **Pelorus** AI navigator inside **LXC / LXD / Proxmox VE** containers.

Supports both **KDE Plasma** and **XFCE**, running under native `systemd --user` session management without requiring Docker or nested container engines.

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
  - **XFCE**: Uses **Labwc** (wlroots-based stacking compositor) nested client on `wayland-1`, hosting `wayland-0` and XWayland.
- **Pelorus AI Navigation Agent**: Integrated FastAPI agent (port 5100, reverse-proxied at `/pelorus/`), reading window states and accessibility trees via AT-SPI2 / D-Bus and executing actions through Pixelflux's token-authenticated Computer Use API (port 5000).
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
|   | Nested Desktop Compositor (wayland-0)                                         |   |
|   |  - KDE: KWin Wayland (kwin-xwayland.py)                                       |   |
|   |  - XFCE: Labwc (wlroots)                                                      |   |
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

### 5. GPU Acceleration (Optional)By default, the installer configures software rendering (`KWIN_COMPOSE=Q`) with multi-threaded `llvmpipe`, ensuring smooth execution on CPU-only hosts.

If GPU passthrough is desired:
- **LXD**:
  ```bash
  lxc config device add <container_name> gpu gpu
  ```
- **Proxmox VE**: Map `/dev/dri/card*` and `/dev/dri/renderD*` devices into the container and ensure the container's `video` and `render` group IDs match the host.
- The installer automatically validates `/dev/dri` permissions and GID mapping during installation.
- Switch to OpenGL rendering by setting `KWIN_COMPOSE=O2` in `~/.config/selkies/selkies.env`.

---

## Installation

### Quick Start

Inside the LXC container as a regular user with `sudo` permissions (or as root; `setup.sh` will automatically switch to the designated user):

```bash
git clone https://github.com/TranceEX/selkies-lxd-wayland.git
cd selkies-lxd-wayland
bash setup.sh
```

During interactive execution, the installer detects any already installed desktop environment and prompts you for:
1. **Desktop Environment & Installation Mode**:
   - `1` for KDE Plasma full install (default)
   - `2` for XFCE full install
   - `3` for Selkies only using existing KDE Plasma (skips desktop packages)
   - `4` for Selkies only using existing XFCE (skips desktop packages)
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

# Install Selkies only for an already installed desktop (skips DE package downloads)
bash setup.sh kde --selkies-only
# or auto-detect installed desktop:
bash setup.sh --selkies-only

# Install only required system packages and dependencies (skips Selkies & services)
bash setup.sh kde --packages-only

# Repair or reconfigure only systemd --user services without reinstalling packages
bash setup.sh --services-only

# Check and fix only the systemd user session (e.g., after pct enter)
bash setup.sh --fix-session
```

#### Available CLI Arguments:
| Argument | Description |
|---|---|
| `kde` / `xfce` | Selects target desktop environment (`kde` = KDE Plasma 6, `xfce` = XFCE 4 with Labwc). |
| `--with-chrome` | Automatically installs Google Chrome (x86_64 only) with hardware decoding. |
| `--no-chrome` | Skips Google Chrome installation prompt. |
| `--selkies-only` | Installs Selkies streaming components and services only, skipping desktop environment packages (for systems with an already installed desktop). |
| `--packages-only` | Installs only required system packages and dependencies, then exits (skips Selkies image extraction, services, and configuration). |
| `--services-only` | Skips package downloads and only writes service files and configuration. |
| `--fix-session` | Diagnoses and repairs the `systemd --user` session bus, then exits. |

#### Supported Environment Variables:
| Variable | Default | Description |
|---|---|---|
| `DESKTOP_ENV` | `kde` | Target desktop environment (`kde` or `xfce`). |
| `INSTALL_CHROME` | `no` | Install Google Chrome (`yes` or `no`). |
| `SELKIES_ONLY` | `0` | Installs Selkies only without installing desktop environment packages (equivalent to `--selkies-only`). |
| `PACKAGES_ONLY` | `0` | Installs only system packages and dependencies (equivalent to `--packages-only`). |
| `SERVICES_ONLY` | `0` | Configures only services and environment files, skipping package installations (equivalent to `--services-only`). |
| `PASSWORD` | *(empty)* | Sets HTTP Basic Authentication password for Nginx web access. |
| `SETUP_USER` | *(auto)* | Target username when script is executed as `root` (e.g. from `pct enter`). |
| `CUSTOM_PORT` | `3000` | Nginx HTTP port. |
| `CUSTOM_HTTPS_PORT` | `3001` | Nginx HTTPS port. |
| `CUSTOM_WS_PORT` | `8082` | Selkies backend WebSocket port. |
| `SUBFOLDER` | `/` | Web application root subfolder. |
| `DISABLE_IPV6` | `true` | Disables IPv6 listener in Nginx. |
| `PELORUS` | `true` | Enables Pelorus AI navigation server. |

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
| **Compositor** | `DESKTOP_ENVIRONMENT` | `kde` | Desktop session: `kde` (KDE Plasma) or `xfce` (XFCE + Labwc). |
| | `KWIN_COMPOSE` | `Q` | Compositor backend: `Q` (software rendering via QPainter/pixman) or `O2` (OpenGL for GPU passthrough). |
| | `PIXELFLUX_WAYLAND` | `true` | Enables Smithay Wayland compositor inside Pixelflux. |
| | `WAYLAND_DISPLAY` | `wayland-1` | Socket hosted by Pixelflux for nested compositor clients. |
| | `SELKIES_APP_WAYLAND_DISPLAY` | `wayland-0` | Socket hosted by KWin / Labwc for session applications. |
| **Streaming** | `CUSTOM_WS_PORT` / `SELKIES_PORT` | `8082` | WebSocket port used by Selkies daemon and Nginx proxy. |
| | `SELKIES_ENCODER` | `h264enc` | Video encoder (`h264enc`, `h265enc`, `vp8enc`, `vp9enc`, `av1enc`, `jpeg`). |
| | `SELKIES_FRAMERATE` | `60` | Target stream frame rate. |
| | `SELKIES_COMMAND_ENABLED` | `true` | Enables WebSocket commands required for Selkies 2.2+ sidebar launcher. |
| **Pelorus AI** | `PELORUS` | `true` | Activates Pelorus AI navigator and UI. |
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

# 5. Check Wayland sockets (both wayland-1 and wayland-0 must exist)
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
