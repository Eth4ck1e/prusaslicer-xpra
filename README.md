# PrusaSlicer — Docker for Unraid

PrusaSlicer running directly in your browser via [Xpra HTML5](https://xpra.org/). PrusaSlicer is compiled from source and delivered as a seamless single-app window — no remote desktop, no VNC client required.

GPU acceleration is supported for Intel Arc, AMD, and NVIDIA via VirtualGL.

**Image:** `ghcr.io/eth4ck1e/prusaslicer-novnc:latest`

---

## Quick Start — Unraid

1. In the Unraid Docker tab, click **Add Container**
2. In the **Template** dropdown, select **prusaslicer-novnc** (see template install below)
3. Set your GPU vendor under **GPU Vendor** (`intel`, `amd`, or `nvidia`)
4. Click **Apply**
5. Open `http://<unraid-ip>:8383` in your browser — PrusaSlicer loads directly in the tab

### Installing the template

SSH into your Unraid server and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/prusaslicer-novnc.xml \
  https://raw.githubusercontent.com/Eth4ck1e/prusaslicer-novnc/main/prusaslicer-novnc.xml
```

Then refresh the Docker page and the template will appear in the dropdown.

---

## Features

- **Browser-native delivery** — Xpra HTML5 streams PrusaSlicer directly to your browser tab as a seamless single window
- **Clipboard paste** — copy text on your host (e.g. a Prusa account password) and paste it directly into PrusaSlicer with Ctrl+V
- **File upload** — drag files from your desktop onto the browser tab to open them in PrusaSlicer
- **GPU acceleration** — Intel Arc, AMD, and NVIDIA supported via VirtualGL + Mesa
- **Compiled from source** — built directly from the official PrusaSlicer GitHub repo at each version bump
- **Auto-updates** — daily check for new PrusaSlicer releases; version bumps are committed and built automatically

---

## GPU Setup

### Intel Arc / Intel Gen9+ (default)

Pass through `/dev/dri/` in the Unraid template (default) and set:

| Variable | Value |
|---|---|
| `ENABLEHWGPU` | `true` |
| `GPU_VENDOR` | `intel` |
| `LIBVA_DRIVER_NAME` | `iHD` |

To find your GPU device path in Unraid: **Tools → System Devices** or run `ls /dev/dri/` in the Unraid terminal.

> For older Intel GPUs (Gen8 and below), set `LIBVA_DRIVER_NAME=i965`.

### AMD

Pass through `/dev/dri/` and set:

| Variable | Value |
|---|---|
| `ENABLEHWGPU` | `true` |
| `GPU_VENDOR` | `amd` |
| `LIBVA_DRIVER_NAME` | `radeonsi` |

### NVIDIA

NVIDIA GPUs are handled by the [Unraid NVIDIA plugin](https://forums.unraid.net/topic/98978-plugin-nvidia-driver/) rather than `/dev/dri/`. Remove the **GPU Device** field from the template and set:

| Variable | Value |
|---|---|
| `ENABLEHWGPU` | `true` |
| `GPU_VENDOR` | `nvidia` |
| `NVIDIA_VISIBLE_DEVICES` | `all` (or a specific GPU UUID) |

The NVIDIA Container Toolkit mounts the GPU drivers automatically — no additional packages needed in the container.

### No GPU

Leave `ENABLEHWGPU` unset or set to `false`. PrusaSlicer will run in software rendering mode.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ENABLEHWGPU` | _(unset)_ | Set to `true` to enable VirtualGL GPU acceleration |
| `GPU_VENDOR` | `intel` | GPU driver stack: `intel`, `amd`, or `nvidia` |
| `VNC_RESOLUTION` | `1920x1080` | Virtual display resolution |
| `VNC_PASSWORD` | _(unset)_ | Optional password to protect the session |
| `VGL_DISPLAY` | `egl` | VirtualGL display backend — `egl` works for all GPU types |
| `LIBVA_DRIVER_NAME` | `iHD` | VA-API driver: `iHD` (Intel Arc/Gen9+), `i965` (older Intel), `radeonsi` (AMD) |
| `NVIDIA_VISIBLE_DEVICES` | _(unset)_ | NVIDIA only: `all` or a specific GPU UUID |
| `DISPLAY` | `:10` | X display number — do not change unless you know what you are doing |
| `NOVNC_PORT` | `8080` | Internal port the Xpra HTML5 server listens on (map the host port in the template) |
| `SUPD_LOGLEVEL` | `INFO` | supervisord log verbosity: `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL` |

---

## Volumes

| Path | Required | Description |
|---|---|---|
| `/configs/` | Yes | PrusaSlicer configuration, profiles, and settings — always persist this |
| `/prints/` | No | G-code output directory. Leave unmapped if you use Prusa Connect to send prints directly to your printer. Map to a share if you need network access to exported G-code. |
| `/models/` | No | STL/3MF input files. Leave unmapped if you use the built-in Printables browser. Map to a share if you want to drop files from other machines on your network. |

---

## Running Outside Unraid

### Docker

```bash
docker run -d \
  --name prusaslicer \
  -p 8383:8080 \
  -v prusaslicer-configs:/configs/ \
  ghcr.io/eth4ck1e/prusaslicer-novnc:latest
```

Then open `http://localhost:8383`.

With Intel GPU passthrough:

```bash
docker run -d \
  --name prusaslicer \
  -p 8383:8080 \
  -v prusaslicer-configs:/configs/ \
  --device /dev/dri/ \
  -e ENABLEHWGPU=true \
  -e GPU_VENDOR=intel \
  ghcr.io/eth4ck1e/prusaslicer-novnc:latest
```

### Docker Compose

```bash
docker compose up -d
```

---

## Build System

This repo uses a two-stage build to keep CI fast:

| Image | Trigger | Build time | Purpose |
|---|---|---|---|
| `prusaslicer-novnc-builder:<version>` | Manual / auto-bump | ~90 min | Compiles PrusaSlicer from source |
| `prusaslicer-novnc:latest` | Every push to main | ~3 min | Packages the runtime (Xpra, VirtualGL, GPU drivers) |

### Building locally

```bash
# Build runtime image (requires pre-built builder on GHCR)
docker build -t prusaslicer-novnc:local .
```

### Version bumps

PrusaSlicer version updates are handled automatically: a daily GitHub Actions workflow checks for new upstream releases and, if found, commits a version bump and triggers a full rebuild. No manual intervention required.

To bump manually, go to **Actions → Build PrusaSlicer** and run the workflow with the desired version tag (e.g. `version_2.9.4`).

---

## Credits

Thanks to [helfrichmichael](https://github.com/helfrichmichael) for the original [prusaslicer-novnc](https://github.com/helfrichmichael/prusaslicer-novnc) project that inspired this one.

PrusaSlicer is developed by [Prusa Research](https://www.prusa3d.com/) and is licensed under [AGPL-3.0](https://github.com/prusa3d/PrusaSlicer/blob/master/LICENSE).

---

## Links

- [PrusaSlicer](https://www.prusa3d.com/prusaslicer/)
- [Xpra](https://xpra.org/)
- [VirtualGL](https://virtualgl.org/)
- [supervisord](http://supervisord.org/)
