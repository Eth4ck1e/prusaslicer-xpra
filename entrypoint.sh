#!/bin/bash
set -e
rm -f /tmp/.X*-lock
rm -f /tmp/.X11-unix/X*
export DISPLAY=${DISPLAY:-:0}
DISPLAY_NUMBER=$(echo $DISPLAY | cut -d: -f2)
export NOVNC_PORT=${NOVNC_PORT:-8080}
export VNC_PORT=${VNC_PORT:-5900}
export VNC_RESOLUTION=${VNC_RESOLUTION:-1280x800}
if [ -n "$VNC_PASSWORD" ]; then
  mkdir -p /root/.vnc
  echo "$VNC_PASSWORD" | vncpasswd -f > /root/.vnc/passwd
  chmod 0600 /root/.vnc/passwd
  export VNC_SEC=
else
  export VNC_SEC="-securitytypes TLSNone,X509None,None"
fi
export LOCALFBPORT=$((${VNC_PORT} + DISPLAY_NUMBER))

# GPU acceleration setup
# ENABLEHWGPU=true  — enables VirtualGL (vglrun) for OpenGL acceleration
# GPU_VENDOR        — selects the GPU driver stack (intel | amd | nvidia)
#                     intel (default): iHD VA-API, /dev/dri/ passthrough
#                     amd:             radeonsi VA-API, /dev/dri/ passthrough
#                     nvidia:          NVIDIA EGL via NVIDIA Container Toolkit,
#                                      set NVIDIA_VISIBLE_DEVICES in container config
if [ -n "$ENABLEHWGPU" ] && [ "$ENABLEHWGPU" = "true" ]; then
  export VGLRUN="/usr/bin/vglrun"
  export VGL_DISPLAY="${VGL_DISPLAY:-egl}"

  GPU_VENDOR="${GPU_VENDOR:-intel}"
  case "$GPU_VENDOR" in
    nvidia)
      # NVIDIA libs are mounted by the NVIDIA Container Toolkit at runtime.
      # No VA-API driver needed; NVIDIA_DRIVER_CAPABILITIES must include graphics.
      export NVIDIA_DRIVER_CAPABILITIES="${NVIDIA_DRIVER_CAPABILITIES:-all}"
      ;;
    amd)
      export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-radeonsi}"
      ;;
    intel|*)
      export LIBVA_DRIVER_NAME="${LIBVA_DRIVER_NAME:-iHD}"
      ;;
  esac
else
  export VGLRUN=
  export VGL_DISPLAY="${VGL_DISPLAY:-egl}"
fi

export SUPD_LOGLEVEL="${SUPD_LOGLEVEL:-INFO}"

# fix perms and launch supervisor with the above environment variables
chown -R slic3r:slic3r /home/slic3r/ /configs/ /prints/ /dev/stdout && exec gosu slic3r supervisord -e $SUPD_LOGLEVEL
