#!/bin/bash
# verify-local.sh — Build prusaslicer-xpra locally and verify the container starts.
#
# Usage:
#   ./scripts/verify-local.sh [--help] <version>
#
# Arguments:
#   version   PrusaSlicer version number (e.g., "2.9.5").
#
# What it does:
#   1. Builds the builder image from Dockerfile.builder (PRUSA_VERSION=version_<ver>).
#   2. Builds the runtime image from Dockerfile (PRUSA_VERSION=<ver>) using the
#      locally-built builder (bypasses GHCR pull).
#   3. Starts the container on port 8080 (GPU disabled for headless testing).
#   4. Polls http://localhost:8080/ for up to 60 seconds.
#   5. Collects container logs for 120 seconds.
#   6. Final health check — exits 0 if healthy, 1 otherwise.
#
# Exit codes:
#   0 — Verified: container built, started, responded to health checks, logs collected.
#   1 — Failure at any step (build, start, health, or logs).
#
# Examples:
#   ./scripts/verify-local.sh 2.9.5
#   PRUSA_VERSION=2.9.5 ./scripts/verify-local.sh

set -euo pipefail

# ─────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────
HEALTH_CHECK_URL="http://localhost:8080/"
HEALTH_TIMEOUT_SEC=60
LOG_COLLECT_SEC=120
CONTAINER_NAME="prusaslicer-verify"

# ─────────────────────────────────────────────
# Help / usage
# ─────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: verify-local.sh [--help] <version>

Local build and verification script for prusaslicer-xpra.

Builds the Docker images locally and verifies the container starts correctly.

Arguments:
  version   PrusaSlicer version string (e.g., "2.9.4", "2.9.5")

Options:
  --help    Show this help message and exit

Environment:
  PRUSA_VERSION    Alternative way to specify the version

Examples:
  verify-local.sh 2.9.5
  PRUSA_VERSION=2.9.5 verify-local.sh
USAGE
    exit 0
}

# ─────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) usage ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Usage: $0 [--help] <version>" >&2
            exit 1
            ;;
        *)
            if [ -n "$VERSION" ]; then
                echo "Error: Multiple version arguments provided" >&2
                exit 1
            fi
            VERSION="$1"
            ;;
    esac
    shift
done

# Fallback to environment variable
if [ -z "$VERSION" ]; then
    VERSION="${PRUSA_VERSION:-}"
fi

if [ -z "$VERSION" ]; then
    echo "Error: No version specified." >&2
    echo "Usage: $0 [--help] <version>" >&2
    echo "  or set PRUSA_VERSION environment variable" >&2
    exit 1
fi

# Strip any leading "version_" prefix the user might have included
VERSION="${VERSION#version_}"

# Validate X.Y.Z format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: Version must be in X.Y.Z format (e.g., 2.9.5). Got: $VERSION" >&2
    exit 1
fi

# ─────────────────────────────────────────────
# Pre-flight checks
# ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    echo "Error: docker not found. Please install Docker and try again." >&2
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "Error: Docker daemon is not running or not accessible." >&2
    exit 1
fi

# ─────────────────────────────────────────────
# Set up paths and tags
# ─────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER_TAG="ghcr.io/eth4ck1e/prusaslicer-xpra-builder:${VERSION}"
RUNTIME_TAG="prusaslicer-xpra:verify-${VERSION}"

echo "╔══════════════════════════════════════════════════╗"
echo "║  prusaslicer-xpra local build & verification     ║"
echo "╚══════════════════════════════════════════════════╝"
echo " Version:   ${VERSION}"
echo " Builder:   ${BUILDER_TAG}"
echo " Runtime:   ${RUNTIME_TAG}"
echo " Context:   ${SCRIPT_DIR}"
echo ""

# ─────────────────────────────────────────────
# Cleanup handler
# ─────────────────────────────────────────────
cleanup() {
    echo ""
    echo "── Cleanup ──────────────────────────────────────"
    if docker ps -q --filter "name=${CONTAINER_NAME}" 2>/dev/null | grep -q .; then
        echo "Stopping container ${CONTAINER_NAME}..."
        docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
    if docker ps -aq --filter "name=${CONTAINER_NAME}" 2>/dev/null | grep -q .; then
        echo "Removing container ${CONTAINER_NAME}..."
        docker rm -v -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# Step 1 — Build builder image
# ─────────────────────────────────────────────
echo "── Step 1: Build builder image (Dockerfile.builder) ──"
echo "  (Compiling PrusaSlicer from source — may take 30+ min)"
docker buildx build \
    -f "${SCRIPT_DIR}/Dockerfile.builder" \
    -t "${BUILDER_TAG}" \
    --build-arg "PRUSA_VERSION=version_${VERSION}" \
    "${SCRIPT_DIR}"
echo "✓ Builder image built: ${BUILDER_TAG}"
echo ""

# ─────────────────────────────────────────────
# Step 2 — Build runtime image
# ─────────────────────────────────────────────
echo "── Step 2: Build runtime image (Dockerfile) ─────────"
docker buildx build \
    -t "${RUNTIME_TAG}" \
    --build-arg "PRUSA_VERSION=${VERSION}" \
    "${SCRIPT_DIR}"
echo "✓ Runtime image built: ${RUNTIME_TAG}"
echo ""

# ─────────────────────────────────────────────
# Step 3 — Start container
# ─────────────────────────────────────────────
echo "── Step 3: Start container ──────────────────────────"
# Remove any leftover container from a previous interrupted run
docker rm -v -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true

docker run -d \
    --name "${CONTAINER_NAME}" \
    -p 8080:8080 \
    -e ENABLEHWGPU=false \
    "${RUNTIME_TAG}"

CID=$(docker ps -q --filter "name=${CONTAINER_NAME}")
echo "Container started: ${CID}"
echo ""

# ─────────────────────────────────────────────
# Step 4 — Wait for health (up to 60s)
# ─────────────────────────────────────────────
echo "── Step 4: Health check (${HEALTH_CHECK_URL}, up to ${HEALTH_TIMEOUT_SEC}s) ──"

HEALTHY=false
POLL_INTERVAL=5
MAX_ATTEMPTS=$((HEALTH_TIMEOUT_SEC / POLL_INTERVAL))

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
    sleep "${POLL_INTERVAL}"
    elapsed=$((attempt * POLL_INTERVAL))
    if curl -sf "${HEALTH_CHECK_URL}" >/dev/null 2>&1; then
        echo "✓ Healthy after ${elapsed}s"
        HEALTHY=true
        break
    fi
    echo "  ... waiting (${elapsed}s / ${HEALTH_TIMEOUT_SEC}s)"
done

if [ "${HEALTHY}" != "true" ]; then
    echo "✗ Container did not become healthy within ${HEALTH_TIMEOUT_SEC}s" >&2
    echo ""
    echo "── Container logs (last 60 lines) ─────────────────"
    docker logs "${CONTAINER_NAME}" --tail 60 2>&1 || true
    exit 1
fi
echo ""

# ─────────────────────────────────────────────
# Step 5 — Collect logs for 120s
# ─────────────────────────────────────────────
echo "── Step 5: Collect logs (${LOG_COLLECT_SEC}s) ────────"
LOGFILE="$(mktemp /tmp/prusaslicer-verify-logs-XXXXXX.txt)"
echo "  Logging to: ${LOGFILE}"

docker logs -f "${CONTAINER_NAME}" > "${LOGFILE}" 2>&1 &
LOGS_PID=$!

sleep "${LOG_COLLECT_SEC}"

# Stop log follower
kill "${LOGS_PID}" 2>/dev/null || true
wait "${LOGS_PID}" 2>/dev/null || true

LINE_COUNT=$(wc -l < "${LOGFILE}")
echo "✓ ${LINE_COUNT} log lines collected"
echo "  Logs saved at: ${LOGFILE}"
echo ""

# ─────────────────────────────────────────────
# Step 6 — Final health verification
# ─────────────────────────────────────────────
echo "── Step 6: Final health check ───────────────────────"
if curl -sf "${HEALTH_CHECK_URL}" >/dev/null 2>&1; then
    echo "✓ Container is still healthy"
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  VERIFICATION PASSED                            ║"
    echo "╚══════════════════════════════════════════════════╝"
    exit 0
else
    echo "✗ Container stopped responding" >&2
    echo ""
    echo "── Container logs (last 30 lines) ─────────────────"
    docker logs "${CONTAINER_NAME}" --tail 30 2>&1 || true
    exit 1
fi