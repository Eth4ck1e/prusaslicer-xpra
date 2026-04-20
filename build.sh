#!/bin/bash
# Local build script — works on Apple Silicon (M-series) and Intel Macs.
# Always targets linux/amd64 to match the Unraid server architecture.
#
# Usage:
#   ./build.sh          — build the runtime image only (fast, ~3 min)
#                         requires ghcr.io/eth4ck1e/prusaslicer-xpra-builder:<version> to exist
#   ./build.sh builder  — build the PrusaSlicer builder image (slow, ~90 min)
#                         run this first when bumping the PrusaSlicer version
set -e

PRUSA_VERSION="2.9.4"
BUILDER_IMAGE="ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${PRUSA_VERSION}"
RUNTIME_IMAGE="prusaslicer-xpra:local"

if [ "${1}" = "builder" ]; then
  echo "Building PrusaSlicer builder image (slow — ~90 min)..."
  echo "Target: ${BUILDER_IMAGE}"
  BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx build \
    --platform linux/amd64 \
    --progress=plain \
    --load \
    --build-arg PRUSA_VERSION="version_${PRUSA_VERSION}" \
    -f Dockerfile.builder \
    -t "${BUILDER_IMAGE}" \
    . 2>&1 | tee build-builder.log
  echo ""
  echo "Builder image ready: ${BUILDER_IMAGE}"
  echo "Push to GHCR with: docker push ${BUILDER_IMAGE}"
else
  echo "Building runtime image (fast — requires pre-built builder)..."
  echo "Target: ${RUNTIME_IMAGE}"
  BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx build \
    --platform linux/amd64 \
    --progress=plain \
    --load \
    --build-arg PRUSA_VERSION="${PRUSA_VERSION}" \
    -t "${RUNTIME_IMAGE}" \
    . 2>&1 | tee build.log
  echo ""
  echo "Build complete: ${RUNTIME_IMAGE}"
  echo ""
  echo "To run locally:"
  echo "  docker run --rm --platform linux/amd64 -p 8383:8080 ${RUNTIME_IMAGE}"
  echo "  Then open http://localhost:8383"
fi
