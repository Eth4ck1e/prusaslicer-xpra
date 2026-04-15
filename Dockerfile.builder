ARG UBUNTU_VERSION=22.04

# ─────────────────────────────────────────────
# Builds PrusaSlicer from source and installs to /prusa-install.
# Push to GHCR with: ghcr.io/eth4ck1e/prusaslicer-novnc-builder:<version>
# Trigger: manual only via build-prusaslicer.yml workflow.
# ─────────────────────────────────────────────
FROM ubuntu:${UBUNTU_VERSION}

# Git tag to build. Override at build time: --build-arg PRUSA_VERSION=version_2.9.4
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
    libwebkit2gtk-4.0-dev \
    libtbb-dev \
    zlib1g-dev libjpeg-dev libpng-dev libtiff-dev \
    libboost-all-dev \
    python3 wget curl \
    && rm -rf /var/lib/apt/lists/*

# ccache persists compiled objects across builds via BuildKit cache mount.
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
      -DSLIC3R_BUILD_ID=noVNC \
      -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build -j4 \
    && cmake --install build --prefix /prusa-install
