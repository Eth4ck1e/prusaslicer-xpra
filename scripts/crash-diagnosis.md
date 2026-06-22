# Crash Loop Diagnosis — prusaslicer-xpra Docker Container

## Summary

The prusaslicer-xpra Docker container builds successfully (all docker.yml CI runs pass) but enters a **runtime crash loop** when started: the container stays in a `running` state but xpra and/or PrusaSlicer restart repeatedly via supervisord's `autorestart=true`, preventing the web UI from ever becoming available on port 8080.

## Architecture

```
Docker CMD/ENTRYPOINT
  └─ entrypoint.sh (runs as root, set -e)
      1. Kill stale Xvfb, clean /tmp/.X*-lock
      2. Set env vars (DISPLAY, XPRA_PORT, GPU config)
      3. Build PRUSA_CMD (with/without vglrun)
      4. Generate /tmp/xpra-start.sh via heredoc
      5. chown -R slic3r:slic3r /configs/ /prints/ /models/
      6. exec gosu slic3r supervisord
            └─ supervisord.conf (autorestart=true)
                 └─ /tmp/xpra-start.sh (PID 1 for supervisor)
                      └─ xpra start :10 --no-daemon
                           └─ --start-child="bash -c 'sleep 2 && prusa-slicer ...'"
                           └─ --exit-with-children=yes
                           └─ --xvfb="Xvfb -screen 0 1920x1080x24 ..."
```

## Crash Mechanism

When the child process (PrusaSlicer) crashes or fails to start:

1. `xpra` (with `--exit-with-children=yes`) detects the child has exited
2. `xpra` exits (foreground process managed by supervisord)
3. `supervisord` (configured with `autorestart=true`) restarts `/tmp/xpra-start.sh`
4. Steps 1-3 repeat indefinitely → **internal crash loop**
5. `HEALTHCHECK` (curl http://localhost:8080/) repeatedly fails → Docker marks container "unhealthy"
6. The container appears "running" to Docker but the web service never comes up

## Key Evidence

### Evidence 1: No Runtime Testing in CI
The `docker.yml` (Publish to GHCR) workflow only **builds and pushes** the image — it never starts a container or validates runtime behavior. All 10 recent runs are `success`, but none tested the actual startup.

```
Run 27925813167: Publish to GHCR (success) — Steps: checkout, login, tag, buildx, push
No runtime container test step exists in docker.yml.
```

### Evidence 2: PR #68 Explicitly Documents the Crash Loop
> "The Docker container is in a crash loop — builds and deploys fine but crashes at runtime. We need a local testing workflow to catch runtime issues before they reach production."
> — PR #68 body (build-and-test.sh, created to reproduce this crash)

### Evidence 3: Prior Xvfb Cleanup Fix Was Partial
Commit `e69e477` ("Fix xpra crash loop: kill lingering Xvfb before socket cleanup") addressed socket contention on supervisord restart but did NOT fix the root cause — PrusaSlicer/xpra still crashes, just now with cleaner restarts.

### Evidence 4: Upstream PrusaSlicer 2.9.5 Release Has No OS-Level Breaking Changes
The `2.9.4 → 2.9.5` bump (commit `92dc3ef`) only changed two `ARG PRUSA_VERSION` lines. No Dockerfile, entrypoint, or dependency changes. The crash is not version-specific.

### Evidence 5: xpra Version Mismatch Risk
- xpra server installed from `jammy main` on `xpra.org`: **v6.2.1-r0-1**
- xpra-html5 also from `jammy main`: **v16.2-r0-1**
- Standard Ubuntu 22.04 provides xpra **v3.1** — completely different codebase
- The `jammy beta` channel in the Dockerfile's apt sources is **empty** (no packages), falling through to Ubuntu's universe repo (v3.1)
- Both `jammy beta` and `jammy main` are added, but the actual xpra 6.x packages come from `jammy main` on xpra.org

## Root Cause Analysis

### Primary Cause: PrusaSlicer Crashes Under Xvfb (GPU/Display Initialization)

The most likely root cause is that **PrusaSlicer 2.9.5's OpenGL/GTK initialization crashes when launched under Xvfb without hardware GPU acceleration**, due to:

**a) Mesa software rasterizer (llvmpipe) GL version mismatch:**
- Xvfb with `+extension Composite +extension RANDR +extension RENDER` provides software OpenGL via Mesa
- PrusaSlicer 2.9.5 requires OpenGL 3.3+ for its 3D viewport
- Xvfb's Mesa/llvmpipe on Ubuntu 22.04 may only provide GL 2.1 or may crash on GL 3.x context creation
- Result: PrusaSlicer segfaults on GL context creation during startup

**b) VirtualGL (vglrun) failure on Unraid with default GPU settings:**
- The Unraid template `prusaslicer-xpra.xml` defaults: `ENABLEHWGPU=true`, `GPU_VENDOR=intel`
- When `ENABLEHWGPU=true`, PRUSA_CMD is prefixed with `/usr/bin/vglrun`
- vglrun needs EGL access to `/dev/dri/` — if missing, misconfigured, or insufficient permissions, vglrun fails
- The `&&` chain in `--start-child="bash -c 'sleep 2 && vglrun prusa-slicer ...'"` means vglrun failure prevents prusa-slicer from starting

**c) Missing or incorrect Mesa/GL library version:**
- The runtime Dockerfile installs `libgl1-mesa-glx` and `libgl1-mesa-dri` — these provide llvmpipe
- But the dev package `libwebkit2gtk-4.0-dev` is used instead of runtime `libwebkit2gtk-4.0-37` — this pulls in many unnecessary dev dependencies that could conflict
- Missing EGL software rendering support (`libegl-mesa0` IS installed, but might not include the software backend)

### Secondary Cause: Build-and-Test Script Env Var Bug

The `build-and-test.sh` script sets `-e ENABLE_VIRTUALGL=1` (wrong variable name — entrypoint checks for `ENABLEHWGPU=true`). This means the test script always tests WITHOUT VirtualGL, meaning it tests a different configuration than the default Unraid deployment tests (which has ENABLEHWGPU=true). This mismatch means the script might not reproduce the exact Unraid crash scenario.

### Tertiary Findings (Lower Confidence)

- **gosu availability**: Verified `gosu` is available via Ubuntu 22.04 universe repo (v1.14) — not a problem
- **chown /dev/stdout**: Verified `chown` on `/dev/stdout` succeeds inside Docker — not a problem
- **Xvfb lock cleanup**: Already addressed by commit e69e477 (partially, may still race on very fast restart cycles)
- **supervisord autorestart**: Correctly configured, but `stopwaitsecs=10` may not give xpra enough time to cleanly shut down before restart

## How to Reproduce

Using `scripts/build-and-test.sh`:

```bash
./scripts/build-and-test.sh --quick
```

This will:
1. Pull the builder image from GHCR
2. Build the runtime image
3. Start a container with DISPLAY=:99 (no GPU)
4. Wait up to 120s for startup signals
5. Report pass/fail

Expected result without a fix: **Container enters crash loop** — the script detects one of:
- Container exits within 120s → "Crash loop detected"
- Container runs but xpra/PrusaSlicer never produce startup signals → "TIMEOUT"

To test with the Unraid default GPU configuration:
```bash
docker run -d --name crash-test \
  -e ENABLEHWGPU=true \
  -e GPU_VENDOR=intel \
  ghcr.io/eth4ck1e/prusaslicer-xpra:latest
docker logs -f crash-test  # Watch the crash/restart cycle
```

## Proposed Fixes

### Fix 1: Graceful Error Handling for PrusaSlicer Start Failure (HIGHEST PRIORITY)
**File:** `entrypoint.sh`

Replace the `--exit-with-children=yes` xpra flag with a more resilient startup that doesn't crash the entire container when PrusaSlicer fails:

```bash
# Option A: Remove --exit-with-children=yes so xpra stays running
# even if PrusaSlicer crashes. The HTML5 interface remains accessible.
# Remove: --exit-with-children=yes

# Option B: Wrap prusa-slicer in a retry loop with backoff
--start-child="/bin/bash -c 'for i in 1 2 3; do sleep 2 && ${PRUSA_CMD} && break || sleep 5; done'"
```

### Fix 2: Set LIBGL_ALWAYS_SOFTWARE for Reliable Software Rendering (HIGH PRIORITY)
**File:** `entrypoint.sh`

Force Mesa to use the software rasterizer even when a GPU device is present but misconfigured:

```bash
if [ -z "$VGLRUN" ]; then
  export LIBGL_ALWAYS_SOFTWARE=true
  export GALLIUM_DRIVER=llvmpipe
fi
```

### Fix 3: Fix Build-and-Test Script Env Var Name (MEDIUM PRIORITY)
**File:** `scripts/build-and-test.sh`

```bash
# Change: -e ENABLE_VIRTUALGL=1
# To:     -e ENABLEHWGPU=true
```

### Fix 4: Replace `libwebkit2gtk-4.0-dev` with Runtime Library (LOW PRIORITY)
**File:** `Dockerfile`

```diff
- libwebkit2gtk-4.0-dev
+ libwebkit2gtk-4.0-37
```

## Confidence

**Medium-High**. The root cause is clear: PrusaSlicer (or xpra's child process) crashes at startup under Xvfb without hardware GL support. The specific crash mechanism (GL context failure, vglrun failure, or GTK display init) requires container runtime logs to pinpoint. Fix 1 (remove `--exit-with-children=yes`) is the highest-impact change — it breaks the crash-restart cycle regardless of the specific crash cause.

## Open Questions / Risks

1. **Is it PrusaSlicer or xpra that crashes first?** Without container logs from an actual crash, the exact crash site is unknown. Fix 1 handles both.
2. **Does `--resize-display=no` with `--desktop-scaling=1` cause PrusaSlicer to render off-screen?** If the display isn't resized to match the actual client window, PrusaSlicer's window might be partially off the Xvfb screen.
3. **Will removing `--exit-with-children=yes` leave orphan xpra processes?** Supervisord handles lifecycle with `autorestart=true` — when PrusaSlicer crashes, xpra stays alive serving the HTML5 interface. This is acceptable.
4. **The `xpra-x11` package from xpra.org may conflict with xpra 6.x configuration format.** If the xpra 6.x config format changed, the `/etc/xpra/conf.d/99-docker.conf` `opengl=no` setting might be ignored.
