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
#   JOURNAL_NAME_FORMAT - strftime format for the notebook name; defaults to
#                       DATE_FORMAT. Add literal text to taste, e.g.
#                       "Journal %Y-%m-%d" or "%Y-%m-%d - Work".
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
# Notebook name (a strftime format). Defaults to DATE_FORMAT, so the name is the
# date unless customised, e.g. JOURNAL_NAME_FORMAT="Journal %Y-%m-%d" or
# "%Y-%m-%d - Work". Keep an ISO date in it so cleanup can recognise journals.
JOURNAL_NAME_FORMAT="${JOURNAL_NAME_FORMAT:-$DATE_FORMAT}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-1}"
TEMPLATE_STYLE="${TEMPLATE_STYLE:-lined}"
DRY_RUN="${DRY_RUN:-false}"

# Notebook name from today (or a provided YYYY-MM-DD argument).
if [ -n "$1" ]; then
    JOURNAL_NAME=$(date -d "$1" +"$JOURNAL_NAME_FORMAT")
else
    JOURNAL_NAME=$(date +"$JOURNAL_NAME_FORMAT")
fi

# Temp directory for working files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Creating daily journal: $JOURNAL_NAME"
log "Target folder: $REMARKABLE_FOLDER"
log "Template: $TEMPLATE_STYLE, pages: $TEMPLATE_PAGES"

# Build the native notebook. rmapi put uses the file's basename as the cloud
# visibleName, so name the .rmdoc after JOURNAL_NAME (slashes → dashes so an
# unusual JOURNAL_NAME_FORMAT can't escape the temp dir).
SAFE_NAME="${JOURNAL_NAME//\//-}"
RMDOC_FILE="$TEMP_DIR/$SAFE_NAME.rmdoc"
JOURNAL_NAME="$JOURNAL_NAME" \
TEMPLATE_STYLE="$TEMPLATE_STYLE" \
TEMPLATE_PAGES="$TEMPLATE_PAGES" \
OUTPUT_FILE="$RMDOC_FILE" \
    "$SCRIPT_DIR/generate-native-journal.sh"

if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN: Would upload '$JOURNAL_NAME' to $REMARKABLE_FOLDER"
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

# Check if a notebook with this exact name already exists
if rmapi ls "$REMARKABLE_FOLDER" 2>/dev/null | sed 's/^\[f\][[:space:]]*//' | grep -qxF "$JOURNAL_NAME"; then
    log "Note '$JOURNAL_NAME' already exists, skipping upload."
    exit 0
fi

# Upload to reMarkable
log "Uploading to reMarkable..."
rmapi put "$RMDOC_FILE" "$REMARKABLE_FOLDER"

log "✓ Daily journal created successfully: $JOURNAL_NAME"
