#!/bin/bash
# check-builder-image.sh — Check if a PrusaSlicer builder image exists on GHCR.
#
# Usage:
#   ./check-builder-image.sh <version>
#
# Arguments:
#   version   PrusaSlicer version string (e.g., "2.9.4", "2.9.5")
#
# Returns:
#   0 — builder image exists in GHCR
#   1 — builder image does not exist OR an error occurred
#
# The image tag is constructed as:
#   ghcr.io/eth4ck1e/prusaslicer-xpra-builder:<version>
#
# Examples:
#   ./check-builder-image.sh 2.9.4    # → 0 if 2.9.4 builder was ever built
#   ./check-builder-image.sh 0.0.0    # → 1 (non-existent version)
set -e

# ---- Pre-flight checks ----

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>" >&2
  echo "  e.g. $0 2.9.4" >&2
  exit 1
fi

VERSION="$1"

if ! command -v docker &>/dev/null; then
  echo "Error: 'docker' not found. Please install Docker and try again." >&2
  exit 1
fi

# ---- Construct image reference ----

REGISTRY="ghcr.io"
OWNER="eth4ck1e"
IMAGE="${REGISTRY}/${OWNER}/prusaslicer-xpra-builder:${VERSION}"

# ---- Check image existence ----

if docker manifest inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Builder image exists: ${IMAGE}"
  exit 0
else
  echo "Builder image NOT found: ${IMAGE}"
  exit 1
fi
