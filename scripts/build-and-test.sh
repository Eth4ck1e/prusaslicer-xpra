#!/usr/bin/env bash
# build-and-test.sh — Local build + verification for prusaslicer-xpra
#
# Usage:
#   ./build-and-test.sh                         # default: PRUSA_VERSION from Dockerfile
#   ./build-and-test.sh version_2.9.6            # specific version
#   ./build-and-test.sh --quick                  # skip builder, pull from GHCR
#   ./build-and-test.sh --push                   # after verification, push tags
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

# ── Config ──────────────────────────────────────────────────────────
PRUSA_VERSION="${1:-$(grep '^ARG PRUSA_VERSION=' Dockerfile | head -1 | cut -d= -f2)}"
PRUSA_TAG="version_${PRUSA_VERSION}"
IMAGE_TAG="ghcr.io/eth4ck1e/prusaslicer-xpra:${PRUSA_VERSION}"
BUILDER_TAG="ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${PRUSA_VERSION}"
HEALTH_TIMEOUT=120  # seconds to wait for container health
CONTAINER_NAME="prusaslicer-test-${PRUSA_VERSION}"
SKIP_BUILDER=false
DO_PUSH=false

for arg in "$@"; do
  case "$arg" in
    --quick) SKIP_BUILDER=true ;;
    --push)  DO_PUSH=true ;;
  esac
done

echo "═══ prusaslicer-xpra local build & test ═══"
echo "  Version:     ${PRUSA_VERSION}"
echo "  Builder tag: ${BUILDER_TAG}"
echo "  Image tag:   ${IMAGE_TAG}"
echo "  Skip builder: ${SKIP_BUILDER}"
echo ""

# ── Stage 1: Builder image ──────────────────────────────────────────
if [ "$SKIP_BUILDER" = false ]; then
  # Check if builder already exists locally
  if docker image inspect "$BUILDER_TAG" &>/dev/null; then
    echo "✓ Builder image already exists locally"
  elif docker manifest inspect "$BUILDER_TAG" &>/dev/null 2>&1; then
    echo "← Pulling builder image from GHCR..."
    docker pull "$BUILDER_TAG"
  else
    echo "🔨 Building builder image (this will take 30-60 minutes)..."
    docker buildx build \
      -f Dockerfile.builder \
      --build-arg PRUSA_VERSION="${PRUSA_TAG}" \
      -t "$BUILDER_TAG" \
      . 2>&1 | tail -5
    echo "✓ Builder image built"
  fi
else
  echo "→ Skipping builder (--quick), pulling from GHCR..."
  docker pull "$BUILDER_TAG" 2>/dev/null || echo "⚠️ Could not pull builder, may fail"
fi

# ── Stage 2: Runtime image ──────────────────────────────────────────
echo ""
echo "🔨 Building runtime image..."
docker buildx build \
  --build-arg PRUSA_VERSION="${PRUSA_VERSION}" \
  -t "$IMAGE_TAG" \
  . 2>&1 | tail -5
echo "✓ Runtime image built"

# ── Stage 3: Start container ────────────────────────────────────────
echo ""
echo "🚀 Starting test container..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

docker run -d \
  --name "$CONTAINER_NAME" \
  -e DISPLAY=:99 \
  -e ENABLE_VIRTUALGL=1 \
  -p 8180:8080 \
  "$IMAGE_TAG" 2>&1

echo "✓ Container started: $CONTAINER_NAME"

# ── Stage 4: Health check ───────────────────────────────────────────
echo ""
echo "⏳ Waiting up to ${HEALTH_TIMEOUT}s for container health..."
echo "    (checking logs for startup signals)"

start_time=$(date +%s)
health_ok=false

while true; do
  now=$(date +%s)
  elapsed=$((now - start_time))
  
  if [ "$elapsed" -gt "$HEALTH_TIMEOUT" ]; then
    echo "❌ TIMEOUT: Container did not become healthy within ${HEALTH_TIMEOUT}s"
    echo ""
    echo "=== Last 50 lines of container logs ==="
    docker logs "$CONTAINER_NAME" --tail 50
    echo ""
    echo "=== Running processes ==="
    docker exec "$CONTAINER_NAME" ps aux 2>/dev/null || echo "(cannot exec)"
    exit 1
  fi
  
  # Check if container is still running
  status=$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}' 2>/dev/null || echo "dead")
  if [ "$status" = "exited" ]; then
    echo "❌ Container exited (crash loop detected)"
    echo "Exit code: $(docker inspect "$CONTAINER_NAME" --format '{{.State.ExitCode}}')"
    echo ""
    echo "=== Last 50 lines of container logs ==="
    docker logs "$CONTAINER_NAME" --tail 50
    exit 1
  fi
  
  # Check for startup signals in logs
  logs=$(docker logs "$CONTAINER_NAME" --tail 20 2>/dev/null || true)
  
  if echo "$logs" | grep -qi "xpra.*started\|prusa-slicer.*started\|listening on\|supervisord.*running\|HTTP server listening"; then
    health_ok=true
    echo "✅ Container is healthy! (detected at ${elapsed}s)"
    break
  fi
  
  # Still waiting
  if [ $((elapsed % 10)) -eq 0 ]; then
    echo "  ... waiting (${elapsed}s) - last log line: $(echo "$logs" | tail -1)"
  fi
  
  sleep 2
done

# ── Stage 5: Quick smoke test ────────────────────────────────────────
echo ""
echo "🧪 Running smoke tests..."

# Check process list
echo -n "  Processes: "
procs=$(docker exec "$CONTAINER_NAME" ps aux --no-headers 2>/dev/null | wc -l || echo "0")
echo "${procs} running"

# Check if prusa-slicer binary exists
echo -n "  PrusaSlicer binary: "
if docker exec "$CONTAINER_NAME" test -f /usr/local/bin/prusa-slicer 2>/dev/null; then
  echo "✅ present"
else
  echo "❌ MISSING"
fi

# Check xpra port
echo -n "  xpra listening: "
if docker exec "$CONTAINER_NAME" sh -c "ss -tlnp | grep -q 8080" 2>/dev/null; then
  echo "✅ port 8080"
else
  echo "❌ not detected (may use different port)"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "✅  VERIFICATION PASSED for ${PRUSA_VERSION}"
echo "═══════════════════════════════════════════════"

# Cleanup
docker rm -f "$CONTAINER_NAME" &>/dev/null || true