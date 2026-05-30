#!/bin/bash
#
# create-daily-note.sh
# Creates a dated daily journal notebook and uploads to reMarkable via rmapi.
#
# The notebook is a NATIVE reMarkable document (.rmdoc) that references one of
# the device's built-in templates by name (e.g. "P Lines medium"). The device
# renders the template itself, so we no longer generate a PDF. See
# generate-native-journal.sh for the bundle construction.
#
# Environment variables:
#   REMARKABLE_FOLDER - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT       - Date format for the notebook name (default: %Y-%m-%d)
#   TEMPLATE_PAGES    - Number of pages (default: 1). Pages added on the device
#                       inherit the current page's template automatically.
#   TEMPLATE_STYLE    - Template: blank, lined, grid, checklist, or any raw
#                       reMarkable template name (default: lined -> "P Lines medium")
#   DRY_RUN           - Set to "true" to skip upload
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-1}"
TEMPLATE_STYLE="${TEMPLATE_STYLE:-lined}"
DRY_RUN="${DRY_RUN:-false}"

# Use provided date or default to today
if [ -n "$1" ]; then
    TARGET_DATE="$1"
    FORMATTED_DATE=$(date -d "$TARGET_DATE" +"$DATE_FORMAT")
else
    FORMATTED_DATE=$(date +"$DATE_FORMAT")
fi

# Temp directory for working files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Creating daily journal: $FORMATTED_DATE"
log "Target folder: $REMARKABLE_FOLDER"
log "Template: $TEMPLATE_STYLE, pages: $TEMPLATE_PAGES"

# Build the native notebook. The notebook name (visibleName) is the formatted
# date, so every uploaded file comes in correctly dated.
RMDOC_FILE="$TEMP_DIR/${FORMATTED_DATE}.rmdoc"
JOURNAL_NAME="$FORMATTED_DATE" \
TEMPLATE_STYLE="$TEMPLATE_STYLE" \
TEMPLATE_PAGES="$TEMPLATE_PAGES" \
OUTPUT_FILE="$RMDOC_FILE" \
    "$SCRIPT_DIR/generate-native-journal.sh"

if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN: Would upload $FORMATTED_DATE to $REMARKABLE_FOLDER"
    exit 0
fi

# Check rmapi authentication
if ! rmapi ls / > /dev/null 2>&1; then
    log "ERROR: rmapi not authenticated. Run container interactively first to authenticate."
    log "       docker run -it -v rmapi-config:/app/.config/rmapi remarkable-daily-journal auth"
    exit 1
fi

# Ensure the folder exists on reMarkable
log "Ensuring folder exists: $REMARKABLE_FOLDER"
rmapi mkdir "$REMARKABLE_FOLDER" 2>/dev/null || true

# Check if a notebook with this name already exists
if rmapi find "$REMARKABLE_FOLDER" "^${FORMATTED_DATE}" 2>/dev/null | grep -q "$FORMATTED_DATE"; then
    log "Note for $FORMATTED_DATE already exists, skipping upload."
    exit 0
fi

# Upload to reMarkable
log "Uploading to reMarkable..."
rmapi put "$RMDOC_FILE" "$REMARKABLE_FOLDER"

log "✓ Daily journal created successfully: $FORMATTED_DATE"
