#!/bin/bash
set -e

# Kill any lingering Xvfb processes and clean up stale X lock/socket files (runs as root)
pkill -f "Xvfb" 2>/dev/null || true
rm -f /tmp/.X*-lock
rm -f /tmp/.X11-unix/X*

export DISPLAY=${DISPLAY:-:10}
export NOVNC_PORT=${NOVNC_PORT:-8080}
export VNC_RESOLUTION=${VNC_RESOLUTION:-1920x1080}

# GPU acceleration setup
# ENABLEHWGPU=true  — enables VirtualGL (vglrun) for OpenGL acceleration
# GPU_VENDOR        — selects the GPU driver stack (intel | amd | nvidia)
if [ -n "$ENABLEHWGPU" ] && [ "$ENABLEHWGPU" = "true" ]; then
  export VGLRUN="/usr/bin/vglrun"
  export VGL_DISPLAY="${VGL_DISPLAY:-egl}"

  case "${GPU_VENDOR:-intel}" in
    nvidia)
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
  export VGLRUN=""
  export VGL_DISPLAY="${VGL_DISPLAY:-egl}"
fi

# Build the PrusaSlicer launch command
PRUSA_CMD="/usr/local/bin/prusa-slicer --datadir /configs/.config/PrusaSlicer/"
if [ -n "$VGLRUN" ]; then
  PRUSA_CMD="$VGLRUN $PRUSA_CMD"
fi

# Optional password protection
XPRA_AUTH_ARGS=""
if [ -n "$VNC_PASSWORD" ]; then
  echo "$VNC_PASSWORD" > /tmp/xpra.passwd
  chmod 0600 /tmp/xpra.passwd
  XPRA_AUTH_ARGS="--auth=file:filename=/tmp/xpra.passwd"
fi

# Pre-seed PrusaSlicer's last output path to /prints/ on first launch
PRUSA_APP_CONFIG="/configs/.config/PrusaSlicer/PrusaSlicer.ini"
if [ ! -f "$PRUSA_APP_CONFIG" ] || ! grep -q "^last_output_path" "$PRUSA_APP_CONFIG" 2>/dev/null; then
  mkdir -p "$(dirname "$PRUSA_APP_CONFIG")"
  echo "last_output_path=/prints/" >> "$PRUSA_APP_CONFIG"
fi

export SUPD_LOGLEVEL="${SUPD_LOGLEVEL:-INFO}"

# Write the xpra start script so supervisord can run it cleanly
# (avoids shell quoting issues passing complex commands through supervisord.conf)
DISPLAY_NUM=${DISPLAY#:}

cat > /tmp/xpra-start.sh << EOF
#!/bin/bash
export DISPLAY=${DISPLAY}
export VGL_DISPLAY=${VGL_DISPLAY}
export LIBVA_DRIVER_NAME=${LIBVA_DRIVER_NAME:-}
export NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-}

# Kill any lingering Xvfb and clean up stale display locks on every restart
pkill -f "Xvfb.*:${DISPLAY_NUM}" 2>/dev/null || true
sleep 1
rm -f /tmp/.X${DISPLAY_NUM}-lock /tmp/.X11-unix/X${DISPLAY_NUM}

exec xpra start ${DISPLAY} \\
  --start-child="/bin/bash -c 'sleep 2 && ${PRUSA_CMD}'" \\
  --exit-with-children=yes \\
  --html=on \\
  --bind-tcp=0.0.0.0:${NOVNC_PORT} \\
  --session-name=PrusaSlicer \\
  ${XPRA_AUTH_ARGS} \\
  --no-daemon \\
  --sharing=yes \\
  --resize-display=yes \\
  --desktop-scaling=off \\
  --xvfb="Xvfb -screen 0 ${VNC_RESOLUTION}x24 +extension Composite +extension RANDR +extension RENDER -nolisten tcp -noreset" \\
  --dpi=96 \\
  --file-transfer=yes \\
  --pulseaudio=no \\
  --notifications=no
EOF
chmod +x /tmp/xpra-start.sh

# Fix permissions and launch supervisord
chown -R slic3r:slic3r /home/slic3r/ /configs/ /prints/ /models/ /dev/stdout
exec gosu slic3r supervisord -e $SUPD_LOGLEVEL
