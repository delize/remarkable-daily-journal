#!/usr/bin/env bash
#
# generate-template-docs.sh
# Regenerate docs/TEMPLATES.md from assets/templates.json (the canonical list).
# Run after assets/templates.json changes (update-templates.sh does this too).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
JSON="${1:-$REPO_DIR/assets/templates/rmpp.json}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found" >&2; exit 1; }
[ -f "$JSON" ] || { echo "ERROR: $JSON not found" >&2; exit 1; }

HARDWARE=$(jq -r '.hardware // "unknown"' "$JSON")
FIRMWARE=$(jq -r '.firmware // "unknown"' "$JSON")

# Default output: docs/templates/<hardware>.md
OUT="${2:-$REPO_DIR/docs/templates/${HARDWARE}.md}"
mkdir -p "$(dirname "$OUT")"

rows() {  # rows <true|false for landscape>
    jq -r --argjson ls "$1" \
        '.templates[] | select(.landscape == $ls)
         | "| \(.name) | `\(.filename)` | \(.categories | join(", ")) |"' "$JSON"
}

{
cat <<HEADER
# reMarkable templates

The daily journal references a built-in device template by name — the device
renders it, nothing template-related is uploaded. Set the template with the
\`TEMPLATE_STYLE\` env var, which accepts either a friendly alias or any raw
template name from the tables below:

| Alias | Template value |
|-------|----------------|
| \`blank\` | \`Blank\` |
| \`lined\` | \`P Lines medium\` |
| \`grid\` | \`P Grid medium\` |
| \`checklist\` | \`P Checklist\` |

Any other value is passed through verbatim, so you can use any template here —
e.g. \`TEMPLATE_STYLE="P Dots S"\` or \`TEMPLATE_STYLE="P Cornell"\`. The value is
the **filename** column below (exactly, including spaces and capitalisation).

Daily journals are portrait, so prefer the **Portrait** templates. Landscape
(\`LS …\`) templates are listed for completeness.

> Source: \`/usr/share/remarkable/templates/templates.json\` from reMarkable
> \`$HARDWARE\` firmware \`$FIRMWARE\`. Auto-generated — do not edit by hand;
> run scripts/generate-template-docs.sh. The set can differ across firmware.

## Portrait templates

| Name | Template value (\`TEMPLATE_STYLE\`) | Categories |
|------|-----------------------------------|------------|
HEADER
rows false
cat <<'MID'

## Landscape templates

| Name | Template value (`TEMPLATE_STYLE`) | Categories |
|------|-----------------------------------|------------|
MID
rows true
} > "$OUT"

echo "Wrote $OUT (hardware=$HARDWARE firmware=$FIRMWARE, $(jq '.templates|length' "$JSON") templates)"
