#!/bin/bash
set -e

TMPDIR="$(mktemp -d)"
GITHUB_TOKEN="${2:-}"

if [ -n "$GITHUB_TOKEN" ]; then
  CURL_AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
else
  CURL_AUTH=()
fi

# Fetch the last 20 releases and find the most recent one that has a Linux AppImage.
# (Some releases are Windows/macOS only — e.g. PrusaSlicer 2.9.4 shipped no Linux build.)
curl -SsL "${CURL_AUTH[@]}" \
  "https://api.github.com/repos/prusa3d/PrusaSlicer/releases?per_page=20" > "$TMPDIR/releases.json"

# Validate we got a real response
if jq -e '.message' "$TMPDIR/releases.json" > /dev/null 2>&1; then
  echo "ERROR: GitHub API returned an error:" >&2
  jq -r '.message' "$TMPDIR/releases.json" >&2
  exit 1
fi

# Walk releases in order (newest first) and pick the first with a Linux AppImage.
# Prefer older-distros-GTK3 variant; fall back to standard GTK3.
url=$(jq -r '
  .[] |
  .assets[] |
  select(.browser_download_url | test("linux-x64-older-distros-GTK3.*\\.AppImage$")) |
  .browser_download_url
' "$TMPDIR/releases.json" | head -1)

name=$(jq -r '
  .[] |
  .assets[] |
  select(.browser_download_url | test("linux-x64-older-distros-GTK3.*\\.AppImage$")) |
  .name
' "$TMPDIR/releases.json" | head -1)

version=$(jq -r '
  .[] |
  select(.assets[].browser_download_url | test("linux-x64-older-distros-GTK3.*\\.AppImage$")) |
  .tag_name
' "$TMPDIR/releases.json" | head -1)

# Fall back to standard GTK3 AppImage if older-distros variant not found
if [ -z "$url" ] || [ "$url" = "null" ]; then
  url=$(jq -r '
    .[] |
    .assets[] |
    select(.browser_download_url | test("linux-x64-GTK3.*\\.AppImage$")) |
    .browser_download_url
  ' "$TMPDIR/releases.json" | head -1)

  name=$(jq -r '
    .[] |
    .assets[] |
    select(.browser_download_url | test("linux-x64-GTK3.*\\.AppImage$")) |
    .name
  ' "$TMPDIR/releases.json" | head -1)

  version=$(jq -r '
    .[] |
    select(.assets[].browser_download_url | test("linux-x64-GTK3.*\\.AppImage$")) |
    .tag_name
  ' "$TMPDIR/releases.json" | head -1)
fi

if [ -z "$url" ] || [ "$url" = "null" ]; then
  echo "ERROR: Could not find a Linux AppImage in the last 20 PrusaSlicer releases." >&2
  jq -r '.[].tag_name' "$TMPDIR/releases.json" >&2
  exit 1
fi

echo "Found PrusaSlicer ${version} Linux AppImage" >&2

request=$1

case $request in
  url)     echo "$url" ;;
  name)    echo "$name" ;;
  version) echo "$version" ;;
  *)       echo "Unknown request: $request" >&2; exit 1 ;;
esac

exit 0
