ARG UBUNTU_VERSION=22.04
ARG PRUSA_VERSION=2.9.4

# ─────────────────────────────────────────────
# Pull pre-built PrusaSlicer from the builder image.
# To update PrusaSlicer, run the build-prusaslicer.yml workflow first,
# then bump PRUSA_VERSION here.
# ─────────────────────────────────────────────
FROM ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${PRUSA_VERSION} AS builder

# ─────────────────────────────────────────────
# Stage 2: Runtime image
# ─────────────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION}
LABEL authors="vajonam, Michael Helfrich - helfrichmichael, Eth4ck1e"

ARG VIRTUALGL_VERSION=3.1.1-20240228
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies + Mesa/GPU support
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget curl ca-certificates gnupg \
    xorg xauth gosu supervisor dbus-x11 x11-xserver-utils x11-xkb-utils xkb-data \
    locales locales-all libpam0g libxt6 libxext6 \
    xdg-utils jq git bzip2 gpg-agent software-properties-common python3 \
    openssl \
    # Mesa OpenGL / Intel + AMD GPU support
    libgl1-mesa-glx libgl1-mesa-dri libegl1-mesa libegl-mesa0 \
    mesa-vulkan-drivers libvulkan1 \
    mesa-va-drivers \
    libva2 libva-drm2 libva-x11-2 vainfo \
    # Intel Arc VA-API driver
    intel-media-va-driver \
    libdrm2 libdrm-intel1 libdrm-amdgpu1 \
    # Runtime libs needed by compiled PrusaSlicer
    libgtk-3-0 libglu1-mesa libcurl4 libtbb2 libdbus-1-3 \
    libwebkit2gtk-4.0-dev \
    && locale-gen en_US \
    && rm -rf /var/lib/apt/lists/*

# Install Xpra server from beta (contains HTML5 coordinate mismatch fixes)
# and xpra-html5 from stable (beta doesn't ship it as a separate package).
RUN wget -q https://xpra.org/gpg.asc -O- | gpg --dearmor > /usr/share/keyrings/xpra.gpg \
    && printf 'deb [signed-by=/usr/share/keyrings/xpra.gpg] https://xpra.org/ jammy beta\ndeb [signed-by=/usr/share/keyrings/xpra.gpg] https://xpra.org/ jammy main\n' \
       > /etc/apt/sources.list.d/xpra.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends xpra xpra-x11 xpra-html5 \
    && rm -rf /var/lib/apt/lists/*

# Pin the xpra HTML5 floating toolbar to top-right by default.
# Targets the most common element IDs/classes across xpra-html5 versions.
RUN HTML=$(find /usr/share/xpra/www -maxdepth 1 -name "index.html" | head -1) && \
    [ -n "$HTML" ] && sed -i \
      's|</head>|<style>#toolbar,#xpra_toolbar,.toolbar,.xpra-toolbar{right:8px!important;left:auto!important;top:8px!important;}</style></head>|' \
      "$HTML" || true

# Replace xpra's default favicon with the PrusaSlicer icon.
COPY icons/prusaslicer-32x32.png /usr/share/xpra/www/favicon.png

# Xpra server config:
# - Set a sensible initial virtual display size so PrusaSlicer windows open
#   on-screen before the first client connects and triggers a resize
# - Disable opengl forwarding (we use VirtualGL for that, not xpra's path)
RUN mkdir -p /etc/xpra/conf.d && cat > /etc/xpra/conf.d/99-docker.conf << 'EOF'
opengl = no
EOF

# Install VirtualGL for GPU-accelerated OpenGL rendering
RUN wget -qO /tmp/virtualgl_${VIRTUALGL_VERSION}_amd64.deb \
      https://packagecloud.io/dcommander/virtualgl/packages/any/any/virtualgl_${VIRTUALGL_VERSION}_amd64.deb/download.deb?distro_version_id=35 \
    && dpkg -i /tmp/virtualgl_${VIRTUALGL_VERSION}_amd64.deb \
    && rm -f /tmp/*.deb

# Copy installed PrusaSlicer binary and resources from builder stage.
# Resources land in /usr/local/share/PrusaSlicer (build deps prefix), not /prusa-install.
COPY --from=builder /prusa-install/bin/prusa-slicer /usr/local/bin/prusa-slicer
COPY --from=builder /prusa-install/bin/OCCTWrapper.so /usr/local/bin/OCCTWrapper.so
COPY --from=builder /usr/local/share/PrusaSlicer /usr/local/share/PrusaSlicer

# Create slic3r user and set up directories
RUN groupadd slic3r \
    && useradd -g slic3r --create-home --home-dir /home/slic3r slic3r \
    && mkdir -p /configs /prints /models

# Set up config symlinks and GTK bookmarks
RUN mkdir -p /configs/.local /configs/.config \
    && ln -s /configs/.config/ /home/slic3r/ \
    && mkdir -p /home/slic3r/.config/ \
    && echo "XDG_DOWNLOAD_DIR=\"/models/\"" >> /home/slic3r/.config/user-dirs.dirs \
    && echo "file:///models models" >> /home/slic3r/.gtk-bookmarks \
    && echo "file:///prints prints" >> /home/slic3r/.gtk-bookmarks \
    && ln -s /models /home/slic3r/Downloads \
    && chown -R slic3r:slic3r /home/slic3r/ /prints/ /models/ /configs/

ENV PATH=${PATH}:/opt/VirtualGL/bin

ADD entrypoint.sh /entrypoint.sh
ADD supervisord.conf /etc/

VOLUME /configs/
VOLUME /prints/
VOLUME /models/

# Report healthy once Xpra's web interface is accepting connections
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fs http://localhost:8080/ > /dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
