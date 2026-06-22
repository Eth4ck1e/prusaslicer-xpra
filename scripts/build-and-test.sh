#!/usr/bin/env bash
# build-and-test.sh — Local build + verification for prusaslicer-xpra
#
# Usage:
#   ./scripts/build-and-test.sh                    # default: PRUSA_VERSION from Dockerfile
#   ./scripts/build-and-test.sh 2.9.6              # specific version
#   ./scripts/build-and-test.sh --quick            # skip builder build, pull from GHCR
#   ./scripts/build-and-test.sh --quick 2.9.6      # both
#   PLATFORM=linux/arm64 ./scripts/build-and-test.sh  # native arm64 build
#
# Stages:
#   1. Pull or build the builder image
#   2. Build the runtime image
#   3. Start the container
#   4. Health check (wait for xpra/PrusaSlicer to respond)
#   5. Report pass/fail

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

# ── Parse arguments ──────────────────────────────────────────────────
SKIP_BUILDER=false
PRUSA_VERSION=""

for arg in "$@"; do
  case "$arg" in
    --quick) SKIP_BUILDER=true ;;
    *)
      if [ -z "$PRUSA_VERSION" ]; then
        PRUSA_VERSION="$arg"
      fi
      ;;
  esac
done

# Platform: GitHub Actions builds amd64 by default.
# On Apple Silicon (Colima), set PLATFORM=linux/arm64 and ensure the
# builder image exists for that platform, or build the builder locally.
PLATFORM="${PLATFORM:-linux/amd64}"

# If no version specified, read from Dockerfile
if [ -z "$PRUSA_VERSION" ]; then
  PRUSA_VERSION="$(grep '^ARG PRUSA_VERSION=' Dockerfile | head -1 | cut -d= -f2)"
fi

PRUSA_TAG="version_${PRUSA_VERSION}"
IMAGE_TAG="ghcr.io/eth4ck1e/prusaslicer-xpra:${PRUSA_VERSION}"
BUILDER_TAG="ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${PRUSA_VERSION}"
HEALTH_TIMEOUT=120
CONTAINER_NAME="prusaslicer-test-${PRUSA_VERSION}"

echo "═══ prusaslicer-xpra local build & test ═══"
echo "  Version:     ${PRUSA_VERSION}"
echo "  Platform:    ${PLATFORM}"
echo "  Builder tag: ${BUILDER_TAG}"
echo "  Image tag:   ${IMAGE_TAG}"
echo "  Quick mode:  ${SKIP_BUILDER}"
echo ""

# ── Stage 1: Builder image ──────────────────────────────────────────
if [ "$SKIP_BUILDER" = false ]; then
  if docker image inspect "$BUILDER_TAG" &>/dev/null; then
    echo "✓ Builder image already exists locally"
  elif docker manifest inspect "$BUILDER_TAG" &>/dev/null 2>&1; then
    echo "← Pulling builder image from GHCR (platform=${PLATFORM})..."
    docker pull --platform "${PLATFORM}" "$BUILDER_TAG"
  else
    echo "🔨 Building builder image (30-60 min)..."
    docker build \
      -f Dockerfile.builder \
      --build-arg PRUSA_VERSION="${PRUSA_TAG}" \
      -t "$BUILDER_TAG" \
      .
    echo "✓ Builder image built"
  fi
else
  echo "→ Quick mode: pulling builder from GHCR..."
  docker pull --platform "${PLATFORM}" "$BUILDER_TAG" 2>/dev/null \
    || echo "⚠️  Could not pull builder for ${PRUSA_VERSION}"
fi

# ── Stage 2: Runtime image ──────────────────────────────────────────
echo ""
echo "🔨 Building runtime image..."
docker build \
  --build-arg PRUSA_VERSION="${PRUSA_VERSION}" \
  -t "$IMAGE_TAG" \
  .
echo "✓ Runtime image built"

# ── Stage 3: Start container ────────────────────────────────────────
echo ""
echo "🚀 Starting test container..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  --platform "${PLATFORM}" \
  -e DISPLAY=:99 \
  -e ENABLE_VIRTUALGL=1 \
  -p 8180:8080 \
  "$IMAGE_TAG"

echo "✓ Container started: $CONTAINER_NAME"

# ── Stage 4: Health check ───────────────────────────────────────────
echo ""
echo "⏳ Waiting up to ${HEALTH_TIMEOUT}s for startup signals..."
echo "    (monitoring container logs)"

start_time=$(date +%s)
health_ok=false

while true; do
  now=$(date +%s)
  elapsed=$((now - start_time))

  if [ "$elapsed" -gt "$HEALTH_TIMEOUT" ]; then
    echo "❌ TIMEOUT after ${HEALTH_TIMEOUT}s"
    echo ""
    echo "=== Container status ==="
    docker inspect "$CONTAINER_NAME" --format 'Status={{.State.Status}} Exit={{.State.ExitCode}}' 2>/dev/null
    echo ""
    echo "=== Last 60 lines of container logs ==="
    docker logs "$CONTAINER_NAME" --tail 60 2>&1 || true
    echo ""
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    exit 1
  fi

  status=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "dead")
  if [ "$status" = "exited" ]; then
    echo "❌ Container exited (crash loop detected)"
    echo "  Exit code: $(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}')"
    echo ""
    echo "=== Last 60 lines of container logs ==="
    docker logs "$CONTAINER_NAME" --tail 60 2>&1 || true
    echo ""
    docker exec "$CONTAINER_NAME" ps aux 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    exit 1
  fi

  logs=$(docker logs "$CONTAINER_NAME" --tail 10 2>/dev/null || true)
  if echo "$logs" | grep -qiE \
    "xpra.*started|prusa-slicer.*started|listening on|supervisord.*running|HTTP.*listening"; then
    health_ok=true
    echo "✅ Container healthy! (${elapsed}s)"
    break
  fi

  if [ $((elapsed % 10)) -eq 0 ]; then
    last_line=$(echo "$logs" | tail -1)
    echo "  ... waiting (${elapsed}s) last: ${last_line:0:80}"
  fi

  sleep 2
done

# ── Stage 5: Smoke tests ────────────────────────────────────────────
echo ""
echo "🧪 Smoke tests..."

echo -n "  PrusaSlicer binary: "
if docker exec "$CONTAINER_NAME" test -f /usr/local/bin/prusa-slicer 2>/dev/null; then
  echo "✅"
else
  echo "❌ MISSING"
fi

echo -n "  xpra port 8080: "
if docker exec "$CONTAINER_NAME" sh -c "ss -tlnp 2>/dev/null | grep -q :8080" 2>/dev/null; then
  echo "✅ listening"
else
  echo "❌ not detected"
fi

echo -n "  Processes running: "
procs=$(docker exec "$CONTAINER_NAME" ps aux --no-headers 2>/dev/null | wc -l || echo "0")
echo "${procs}"

echo ""
echo "═══════════════════════════════════════════════"
echo "✅  VERIFICATION PASSED for ${PRUSA_VERSION}"
echo "═══════════════════════════════════════════════"

docker rm -f "$CONTAINER_NAME" &>/dev/null || true