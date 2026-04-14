ARG UBUNTU_VERSION=22.04

# ─────────────────────────────────────────────
# Stage 1: Build PrusaSlicer from source
# ─────────────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION} AS builder

# Git tag to build. Defaults to latest release tag.
# Override at build time: --build-arg PRUSA_VERSION=version_2.8.1
ARG PRUSA_VERSION=version_2.9.4

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    git cmake build-essential pkg-config ccache ca-certificates ninja-build \
    autoconf automake libtool texinfo \
    libgtk-3-dev libwxgtk3.0-gtk3-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libcurl4-openssl-dev libssl-dev \
    libudev-dev libdbus-1-dev \
    libtbb-dev \
    zlib1g-dev libjpeg-dev libpng-dev libtiff-dev \
    libboost-all-dev \
    python3 wget curl \
    && rm -rf /var/lib/apt/lists/*

# ccache persists compiled objects across builds via BuildKit cache mount.
# Even if a layer is invalidated, unchanged files won't be recompiled.
ENV CCACHE_DIR=/ccache \
    CMAKE_C_COMPILER_LAUNCHER=ccache \
    CMAKE_CXX_COMPILER_LAUNCHER=ccache

RUN git clone --depth 1 --branch ${PRUSA_VERSION} \
    https://github.com/prusa3d/PrusaSlicer.git /prusa

WORKDIR /prusa

# Patch broken/unreachable download URLs before building deps.
# 1. gmplib.org port 443 is closed — use the GNU FTP mirror.
# 2. libtiff GitLab zip has an unstable hash (GitLab regenerates archives) —
#    replace with the official stable tarball from download.osgeo.org and
#    clear the expected hash so CMake accepts whatever is served.
RUN find deps -name "*.cmake" -exec \
      sed -i 's|https://gmplib.org/download/gmp/|https://ftp.gnu.org/gnu/gmp/|g' {} + \
    && if [ -f deps/TIFF/TIFF.cmake ]; then \
         sed -i \
           's|https://gitlab.com/libtiff/libtiff/-/archive/v4.6.0/libtiff-v4.6.0.zip|https://download.osgeo.org/libtiff/tiff-4.6.0.tar.gz|g' \
           deps/TIFF/TIFF.cmake \
         && sed -i \
           's|5d652432123223338a6ee642a6499d98ebc5a702f8a065571e1001d4c08c37e6||g' \
           deps/TIFF/TIFF.cmake; \
       fi

# Build bundled third-party deps first (slow, but cached as its own layer).
# Use Ninja to avoid make jobserver issues with ExternalProject (e.g. OCCT).
# Linking is RAM-heavy — cap at 4 parallel jobs to avoid OOM.
RUN --mount=type=cache,target=/ccache \
    cmake deps -B build_deps -G Ninja -DDEP_WX_GTK3=ON \
    && cmake --build build_deps -j4

# Build PrusaSlicer itself.
RUN --mount=type=cache,target=/ccache \
    cmake . -B build -G Ninja \
      -DCMAKE_PREFIX_PATH=/prusa/build_deps/destdir/usr/local \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DSLIC3R_STATIC=1 \
      -DSLIC3R_GTK=3 \
      -DSLIC3R_PCH=OFF \
      -DSLIC3R_FHS=1 \
      -DSLIC3R_DESKTOP_INTEGRATION=0 \
      -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j4

# ─────────────────────────────────────────────
# Stage 2: Runtime image
# ─────────────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION}
LABEL authors="vajonam, Michael Helfrich - helfrichmichael, Eth4ck1e"

ARG VIRTUALGL_VERSION=3.1.1-20240228
ARG TURBOVNC_VERSION=3.1.1-20240127
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies + Mesa/Intel GPU support
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget xorg xauth gosu supervisor x11-xserver-utils \
    locales-all libpam0g libxt6 libxext6 dbus-x11 xauth x11-xkb-utils xkb-data python3 xterm novnc \
    lxde gtk2-engines-murrine gnome-themes-standard gtk2-engines-pixbuf gtk2-engines-murrine arc-theme \
    freeglut3 libgtk2.0-dev libwxgtk3.0-gtk3-dev libwx-perl libxmu-dev \
    xdg-utils locales locales-all pcmanfm jq curl git bzip2 gpg-agent software-properties-common \
    openssl \
    # Mesa OpenGL / Intel GPU support
    libgl1-mesa-glx libgl1-mesa-dri libegl1-mesa libegl-mesa0 \
    mesa-vulkan-drivers libvulkan1 \
    libva2 libva-drm2 libva-x11-2 vainfo \
    intel-media-va-driver \
    libdrm2 libdrm-intel1 \
    # Runtime libs needed by compiled PrusaSlicer
    libgtk-3-0 libglu1-mesa libcurl4 libtbb2 libdbus-1-3 \
    libwebkit2gtk-4.0-dev \
    && mkdir -p /usr/share/desktop-directories \
    # Install Firefox without Snap.
    && add-apt-repository ppa:mozillateam/ppa \
    && apt update \
    && apt install -y firefox-esr --no-install-recommends \
    && apt autoclean -y \
    && apt autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Install VirtualGL and TurboVNC
RUN wget -qO /tmp/virtualgl_${VIRTUALGL_VERSION}_amd64.deb https://packagecloud.io/dcommander/virtualgl/packages/any/any/virtualgl_${VIRTUALGL_VERSION}_amd64.deb/download.deb?distro_version_id=35 \
    && wget -qO /tmp/turbovnc_${TURBOVNC_VERSION}_amd64.deb https://packagecloud.io/dcommander/turbovnc/packages/any/any/turbovnc_${TURBOVNC_VERSION}_amd64.deb/download.deb?distro_version_id=35 \
    && dpkg -i /tmp/virtualgl_${VIRTUALGL_VERSION}_amd64.deb \
    && dpkg -i /tmp/turbovnc_${TURBOVNC_VERSION}_amd64.deb \
    && rm -rf /tmp/*.deb

# Copy compiled PrusaSlicer binary and resources from builder stage
COPY --from=builder /prusa/build/src/prusa-slicer /usr/local/bin/prusa-slicer
COPY --from=builder /prusa/resources /usr/share/prusa-slicer/resources

# Create slic3r user and set up directories
RUN groupadd slic3r \
    && useradd -g slic3r --create-home --home-dir /home/slic3r slic3r \
    && mkdir -p /configs /prints \
    && locale-gen en_US

# Set up config symlinks and bookmarks
RUN mkdir -p /configs/.local /configs/.config \
    && ln -s /configs/.config/ /home/slic3r/ \
    && mkdir -p /home/slic3r/.config/ \
    && echo "XDG_DOWNLOAD_DIR=\"/prints/\"" >> /home/slic3r/.config/user-dirs.dirs \
    && echo "file:///prints prints" >> /home/slic3r/.gtk-bookmarks \
    && chown -R slic3r:slic3r /home/slic3r/ /prints/ /configs/

# Generate key for noVNC and cleanup errors
RUN openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/novnc.pem -out /etc/novnc.pem -days 3650 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=localhost" \
    && rm /etc/xdg/autostart/lxpolkit.desktop \
    && mv /usr/bin/lxpolkit /usr/bin/lxpolkit.ORIG

ENV PATH=${PATH}:/opt/VirtualGL/bin:/opt/TurboVNC/bin

ADD entrypoint.sh /entrypoint.sh
ADD supervisord.conf /etc/

# noVNC index page and icons
ADD vncresize.html /usr/share/novnc/index.html
ADD icons/prusaslicer-16x16.png /usr/share/novnc/app/images/icons/novnc-16x16.png
ADD icons/prusaslicer-24x24.png /usr/share/novnc/app/images/icons/novnc-24x24.png
ADD icons/prusaslicer-32x32.png /usr/share/novnc/app/images/icons/novnc-32x32.png
ADD icons/prusaslicer-48x48.png /usr/share/novnc/app/images/icons/novnc-48x48.png
ADD icons/prusaslicer-60x60.png /usr/share/novnc/app/images/icons/novnc-60x60.png
ADD icons/prusaslicer-64x64.png /usr/share/novnc/app/images/icons/novnc-64x64.png
ADD icons/prusaslicer-72x72.png /usr/share/novnc/app/images/icons/novnc-72x72.png
ADD icons/prusaslicer-76x76.png /usr/share/novnc/app/images/icons/novnc-76x76.png
ADD icons/prusaslicer-96x96.png /usr/share/novnc/app/images/icons/novnc-96x96.png
ADD icons/prusaslicer-120x120.png /usr/share/novnc/app/images/icons/novnc-120x120.png
ADD icons/prusaslicer-144x144.png /usr/share/novnc/app/images/icons/novnc-144x144.png
ADD icons/prusaslicer-152x152.png /usr/share/novnc/app/images/icons/novnc-152x152.png
ADD icons/prusaslicer-192x192.png /usr/share/novnc/app/images/icons/novnc-192x192.png

# Set Firefox to run with hardware acceleration when enabled
RUN sed -i 's|exec $MOZ_LIBDIR/$MOZ_APP_NAME "$@"|if [ -n "$ENABLEHWGPU" ] \&\& [ "$ENABLEHWGPU" = "true" ]; then\n  exec /usr/bin/vglrun $MOZ_LIBDIR/$MOZ_APP_NAME "$@"\nelse\n  exec $MOZ_LIBDIR/$MOZ_APP_NAME "$@"\nfi|g' /usr/bin/firefox-esr

VOLUME /configs/
VOLUME /prints/

ENTRYPOINT ["/entrypoint.sh"]
