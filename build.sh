#!/bin/bash
# Local build script — works on Apple Silicon (M-series) and Intel Macs.
# Always targets linux/amd64 to match the Unraid server architecture.
set -e

IMAGE="prusaslicer-novnc:local"

echo "Building ${IMAGE} for linux/amd64..."
BUILDKIT_STEP_LOG_MAX_SIZE=-1 docker buildx build \
  --platform linux/amd64 \
  --progress=plain \
  --load \
  -t "${IMAGE}" \
  . 2>&1 | tee build.log

echo ""
echo "Build complete: ${IMAGE}"
echo ""
echo "To run locally:"
echo "  docker run --rm -p 8080:8080 ${IMAGE}"
echo "  Then open http://localhost:8080"
