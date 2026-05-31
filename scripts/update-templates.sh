#!/usr/bin/env bash
#
# update-templates.sh
# Refresh assets/templates/<hardware>.json (and its docs) from the latest
# reMarkable firmware, using codexctl to download the image and read its
# /usr/share/remarkable/templates/templates.json.
#
# Usage:
#   scripts/update-templates.sh [--hardware rmpp] [--version X.Y.Z.W]
#
#   --hardware  device code understood by codexctl: rmpp (Paper Pro, default),
#               rm2 (reMarkable 2), rm1 (reMarkable 1), ...
#   --version   firmware version to pull (default: latest listed for hardware)
#
# Requires: codexctl (pip install codexctl), jq. Downloads a large firmware
# image to a temp dir and removes it afterwards.
#
set -euo pipefail

HARDWARE="rmpp"
VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hardware|-d) HARDWARE="$2"; shift 2 ;;
    --version|-V)  VERSION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="/usr/share/remarkable/templates/templates.json"
OUT_JSON="$REPO_DIR/assets/templates/${HARDWARE}.json"

for dep in codexctl jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' not found" >&2; exit 1; }
done

# Resolve the latest version if none was given (first version line in `list`).
if [ -z "$VERSION" ]; then
  VERSION=$(codexctl list --hardware "$HARDWARE" 2>/dev/null \
              | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$VERSION" ] || { echo "ERROR: could not determine latest $HARDWARE version" >&2; exit 1; }
fi
echo "Hardware: $HARDWARE   Version: $VERSION"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading firmware (this is large)..."
codexctl download "$VERSION" --hardware "$HARDWARE" --out "$WORK"

IMAGE="$(find "$WORK" -maxdepth 1 -type f ! -name '*.json' | head -1)"
[ -n "$IMAGE" ] || { echo "ERROR: no firmware image downloaded to $WORK" >&2; exit 1; }
echo "Image: $(basename "$IMAGE")"

# Read templates.json out of the image. codexctl may print warnings to stderr;
# take stdout and start at the first JSON brace.
RAW="$(codexctl cat "$IMAGE" "$TEMPLATE_PATH" 2>/dev/null | awk '/{/{seen=1} seen')"
echo "$RAW" | jq empty 2>/dev/null || { echo "ERROR: templates.json not valid JSON" >&2; exit 1; }

# Write the cleaned, stable shape (drop iconCodes/device-private fields).
mkdir -p "$(dirname "$OUT_JSON")"
echo "$RAW" | jq --arg hw "$HARDWARE" --arg fw "$VERSION" '
  {
    hardware: $hw,
    firmware: $fw,
    templates: [ .templates[] | {
      name,
      filename,
      landscape: (.landscape // false),
      categories: (.categories // [])
    } ]
  }' > "$OUT_JSON"

COUNT=$(jq '.templates | length' "$OUT_JSON")
echo "Wrote $OUT_JSON ($COUNT templates)"

# Regenerate the human-readable doc for this hardware.
"$SCRIPT_DIR/generate-template-docs.sh" "$OUT_JSON"
