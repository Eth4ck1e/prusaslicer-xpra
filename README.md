# PrusaSlicer noVNC — Docker for Unraid

PrusaSlicer running in your browser via noVNC. Fork of [helfrichmichael/prusaslicer-novnc](https://github.com/helfrichmichael/prusaslicer-novnc) rebuilt for Intel Arc GPU support, compiled from source, and extended with AMD and NVIDIA GPU support.

**Image:** `ghcr.io/eth4ck1e/prusaslicer-novnc:latest`

---

## Quick Start — Unraid

1. In the Unraid Docker tab, click **Add Container**
2. In the **Template** dropdown, select **prusaslicer-novnc** (if you have the template installed — see below)
3. Set your GPU vendor under **GPU Vendor** (`intel`, `amd`, or `nvidia`)
4. Click **Apply**
5. Open `http://<unraid-ip>:8383` in your browser

### Installing the template

SSH into your Unraid server and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/prusaslicer-novnc.xml \
  https://raw.githubusercontent.com/Eth4ck1e/prusaslicer-novnc/main/prusaslicer-novnc.xml
```

Then refresh the Docker page and the template will appear in the dropdown.

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

The NVIDIA Container Toolkit mounts the GPU drivers automatically — no additional packages are needed in the container.

### No GPU

Leave `ENABLEHWGPU` unset or set to `false`. PrusaSlicer will run in software rendering mode.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ENABLEHWGPU` | _(unset)_ | Set to `true` to enable VirtualGL GPU acceleration |
| `GPU_VENDOR` | `intel` | GPU driver stack: `intel`, `amd`, or `nvidia` |
| `VNC_RESOLUTION` | `1280x800` | Virtual desktop resolution (e.g. `1920x1080`) |
| `VNC_PASSWORD` | _(unset)_ | Optional VNC session password |
| `VGL_DISPLAY` | `egl` | VirtualGL display backend — `egl` works for all GPU types |
| `LIBVA_DRIVER_NAME` | `iHD` | VA-API driver: `iHD` (Intel Arc/Gen9+), `i965` (older Intel), `radeonsi` (AMD) |
| `NVIDIA_VISIBLE_DEVICES` | _(unset)_ | NVIDIA only: `all` or a specific GPU UUID |
| `DISPLAY` | `:0` | X display number — do not change unless you know what you are doing |
| `NOVNC_PORT` | `8080` | Internal noVNC port (the container always listens on 8080; map the host port in the template) |
| `VNC_PORT` | `5900` | Internal TurboVNC port for direct VNC client connections |
| `SUPD_LOGLEVEL` | `INFO` | supervisord log verbosity: `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL` |

---

## Volumes

| Path | Description |
|---|---|
| `/configs/` | PrusaSlicer configuration, profiles, and settings (persist this) |
| `/prints/` | Sliced G-code output directory |

---

## Running Outside Unraid

### Docker

```bash
docker run -d \
  --name prusaslicer-novnc \
  -p 8383:8080 \
  -v prusaslicer-configs:/configs/ \
  -v prusaslicer-prints:/prints/ \
  ghcr.io/eth4ck1e/prusaslicer-novnc:latest
```

Then open `http://localhost:8383`.

With Intel GPU passthrough:

```bash
docker run -d \
  --name prusaslicer-novnc \
  -p 8383:8080 \
  -v prusaslicer-configs:/configs/ \
  -v prusaslicer-prints:/prints/ \
  --device /dev/dri/ \
  -e ENABLEHWGPU=true \
  -e GPU_VENDOR=intel \
  ghcr.io/eth4ck1e/prusaslicer-novnc:latest
```

### Docker Compose

```bash
docker compose up -d
```

### VNC Client

To connect with a dedicated VNC client instead of the browser, expose port 5900:

```bash
-p 5900:5900
```

Then connect your VNC client to `<host>:5900`.

---

## Build System

This repo uses a two-image build strategy to keep CI fast:

| Image | Trigger | Time | Purpose |
|---|---|---|---|
| `prusaslicer-novnc-builder:<version>` | Manual / auto-bump | ~90 min | Compiles PrusaSlicer from source |
| `prusaslicer-novnc:latest` | Every push to main | ~3 min | Adds noVNC/VNC/supervisord stack |

### Building locally

```bash
# Build runtime image only (requires pre-built builder image on GHCR)
./build.sh

# Build PrusaSlicer from source (slow — only needed for version bumps)
./build.sh builder
```

### Version bumps

PrusaSlicer version updates are handled automatically: a daily GitHub Actions workflow checks for new upstream releases and, if found, commits a version bump and triggers a full rebuild. No manual intervention required.

To bump manually, go to **Actions → Build PrusaSlicer** and run the workflow with the desired version tag (e.g. `version_2.9.4`).

---

## Links

- [PrusaSlicer](https://www.prusa3d.com/prusaslicer/)
- [TurboVNC](https://www.turbovnc.org/)
- [VirtualGL](https://virtualgl.org/)
- [noVNC](https://novnc.com/)
- [supervisord](http://supervisord.org/)
- [Original fork — helfrichmichael/prusaslicer-novnc](https://github.com/helfrichmichael/prusaslicer-novnc)
