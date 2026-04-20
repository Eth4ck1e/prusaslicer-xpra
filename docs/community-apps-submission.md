# Unraid Community Applications — Submission & Maintenance Guide

## How Community Applications Works

The CA plugin (by Squid) indexes Docker container templates from registered GitHub
repositories. Once your repo is registered:

- Your template XML is fetched and indexed automatically
- Users can search for and install your container directly from the CA interface
- Template updates (fields, defaults, descriptions) are picked up on the next CA sync
- The `<TemplateURL>` field in the XML is what CA uses to track and re-fetch updates

**The key field:** `<TemplateURL>` must point to the raw GitHub URL of your template XML.
Ours is already set to:
```
https://raw.githubusercontent.com/Eth4ck1e/prusaslicer-xpra/main/prusaslicer-xpra.xml
```

---

## How to Submit (One-Time)

Post in the **Community Applications support thread** on the Unraid forums:

> **Thread:** https://forums.unraid.net/topic/38582-plug-in-community-applications/

Use the draft below. Squid will add your template repository to the CA sources list.
After that, no further action is needed — updates are automatic.

---

## Forum Post Draft

**Subject / first line:** Template submission: PrusaSlicer noVNC

---

Hi, I'd like to submit a template for Community Applications.

**Container:** PrusaSlicer noVNC
**GitHub repo:** https://github.com/Eth4ck1e/prusaslicer-xpra
**Template URL:** https://raw.githubusercontent.com/Eth4ck1e/prusaslicer-xpra/main/prusaslicer-xpra.xml
**Image:** `ghcr.io/eth4ck1e/prusaslicer-xpra:latest`

**Description:**
PrusaSlicer running in the browser via noVNC. Fork of helfrichmichael/prusaslicer-novnc
rebuilt with Intel Arc GPU support, compiled from source (latest release auto-updated),
and extended with AMD and NVIDIA GPU support.

**GPU support:**
- Intel Arc / Gen9+: `/dev/dri/` passthrough, `GPU_VENDOR=intel` (default)
- AMD: `/dev/dri/` passthrough, `GPU_VENDOR=amd`
- NVIDIA: NVIDIA plugin + `NVIDIA_VISIBLE_DEVICES`, `GPU_VENDOR=nvidia`
- No GPU: software rendering (no passthrough needed)

**Key template fields:**
- noVNC web port (default 8383)
- `/configs/` and `/prints/` volume mounts
- `ENABLEHWGPU`, `GPU_VENDOR`, `VNC_RESOLUTION`, `VNC_PASSWORD`
- Advanced: `VGL_DISPLAY`, `LIBVA_DRIVER_NAME`, `NVIDIA_VISIBLE_DEVICES`, `DISPLAY`, `SUPD_LOGLEVEL`

The image is public on GHCR and automatically rebuilt when new PrusaSlicer versions
are released upstream. Thanks!

---

## How to Make Template Updates

Template updates require **no re-submission** after initial registration. Just:

1. Edit `prusaslicer-xpra.xml` in this repo
2. Commit and push to `main`
3. CA will pick up the changes on its next sync (usually within 24 hours)

### What triggers a CA re-sync
- Adding, removing, or renaming template fields (`<Config>` entries)
- Changing defaults, descriptions, or display settings
- Changing the image tag or repository name

### What does NOT require a template change
- New Docker image builds (CA always pulls `:latest` at install time)
- PrusaSlicer version bumps (handled by auto-bump workflow — image updates automatically)

### Template field reference

| XML attribute | Purpose |
|---|---|
| `Name` | Label shown in Unraid UI |
| `Target` | Container-side path or env var name |
| `Default` | Pre-filled value |
| `Type` | `Port`, `Path`, `Variable`, or `Device` |
| `Display` | `always` (shown by default) or `advanced` (hidden under Advanced) |
| `Required` | Whether Unraid flags it as required |
| `Mask` | `true` to hide value (use for passwords) |

---

## Checklist Before Submitting

- [x] `<TemplateURL>` populated with raw GitHub URL
- [x] `<Repository>` is lowercase (`ghcr.io/eth4ck1e/...`)
- [x] Image is public on GHCR
- [x] Default port is unlikely to conflict (8383)
- [x] Icon hosted at stable public URL (raw.githubusercontent.com)
- [x] README covers GPU setup for all three vendors
- [ ] Post submitted to CA support thread
- [ ] Squid confirms repo added to CA sources
