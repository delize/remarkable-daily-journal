#!/bin/bash
#
# cleanup-old-journals.sh
# Removes the previous day's journal if it has not been modified
#
# Environment variables:
#   REMARKABLE_FOLDER - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT       - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED   - Set to "true" to enable cleanup (default: true)
#   SIZE_TOLERANCE    - Max size increase (bytes) before considering edited (default: 5000)
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-5}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
SIZE_TOLERANCE="${SIZE_TOLERANCE:-5000}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"
}

# Exit early if cleanup is disabled
if [ "$CLEANUP_ENABLED" != "true" ]; then
    log "Cleanup disabled (CLEANUP_ENABLED=$CLEANUP_ENABLED)"
    exit 0
fi

# Calculate yesterday's date
YESTERDAY_DATE=$(date -d "yesterday" +"$DATE_FORMAT" 2>/dev/null || date -v-1d +"$DATE_FORMAT")

log "Checking for unused journal from: $YESTERDAY_DATE"

# Create temp directory for operations
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Generate a reference blank PDF to compare against
generate_blank_reference() {
    local output_file="$1"
    local num_pages="$2"

    cat > "$TEMP_DIR/blank.ps" << EOF
%!PS-Adobe-3.0
1 1 $num_pages {
    612 792 scale
    showpage
} for
EOF

    gs -sDEVICE=pdfwrite \
       -dNOPAUSE \
       -dBATCH \
       -dQUIET \
       -dDEVICEWIDTHPOINTS=612 \
       -dDEVICEHEIGHTPOINTS=792 \
       -sOutputFile="$output_file" \
       "$TEMP_DIR/blank.ps"
}

# Check if rmapi is authenticated
if ! rmapi ls / > /dev/null 2>&1; then
    log "ERROR: rmapi not authenticated, skipping cleanup"
    exit 0
fi

# Search for yesterday's journal
SEARCH_RESULT=$(rmapi find "$REMARKABLE_FOLDER" "^${YESTERDAY_DATE}" 2>/dev/null || true)

if [ -z "$SEARCH_RESULT" ]; then
    log "No journal found for $YESTERDAY_DATE, nothing to clean up"
    exit 0
fi

# Extract the full document path from search result
# rmapi find returns lines like: [d] /Daily Journal/2024-01-15 - Monday, January 15, 2024
DOC_PATH=$(echo "$SEARCH_RESULT" | grep "$YESTERDAY_DATE" | head -1 | sed 's/^\[[df]\] //')

if [ -z "$DOC_PATH" ]; then
    log "Could not parse document path from search results"
    exit 0
fi

DOC_NAME=$(basename "$DOC_PATH")
log "Found yesterday's journal: $DOC_NAME"

# Generate reference blank PDF
BLANK_PDF="$TEMP_DIR/blank_reference.pdf"
generate_blank_reference "$BLANK_PDF" "$TEMPLATE_PAGES"
BLANK_SIZE=$(stat -f%z "$BLANK_PDF" 2>/dev/null || stat -c%s "$BLANK_PDF")
log "Reference blank PDF size: $BLANK_SIZE bytes"

# Download yesterday's journal
log "Downloading journal for comparison..."

cd "$TEMP_DIR"
if ! rmapi get "$DOC_PATH" > /dev/null 2>&1; then
    log "Failed to download journal, skipping cleanup"
    exit 0
fi

# rmapi downloads with the document name as filename
DOWNLOADED_FILE=$(find "$TEMP_DIR" -name "*.pdf" -o -name "*.zip" 2>/dev/null | grep -v "blank_reference" | head -1)

if [ -z "$DOWNLOADED_FILE" ] || [ ! -f "$DOWNLOADED_FILE" ]; then
    log "Downloaded file not found, skipping cleanup"
    exit 0
fi

DOWNLOADED_SIZE=$(stat -f%z "$DOWNLOADED_FILE" 2>/dev/null || stat -c%s "$DOWNLOADED_FILE")
log "Downloaded journal size: $DOWNLOADED_SIZE bytes"

# Calculate size difference
SIZE_DIFF=$((DOWNLOADED_SIZE - BLANK_SIZE))
if [ $SIZE_DIFF -lt 0 ]; then
    SIZE_DIFF=$((-SIZE_DIFF))
fi

log "Size difference: $SIZE_DIFF bytes (tolerance: $SIZE_TOLERANCE bytes)"

# If the size difference is within tolerance, the journal was not edited
if [ $SIZE_DIFF -le $SIZE_TOLERANCE ]; then
    log "Journal appears unedited (size within tolerance)"
    log "Removing unused journal: $DOC_PATH"

    if rmapi rm "$DOC_PATH"; then
        log "✓ Successfully removed unused journal: $DOC_NAME"
    else
        log "ERROR: Failed to remove journal"
        exit 1
    fi
else
    log "Journal has been modified (size increased by $SIZE_DIFF bytes)"
    log "Keeping journal: $DOC_NAME"
fi
