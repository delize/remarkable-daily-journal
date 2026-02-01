#!/bin/bash
#
# create-daily-note.sh
# Creates a dated daily journal notebook and uploads to reMarkable via rmapi
#
# Environment variables:
#   REMARKABLE_FOLDER - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT       - Date format for filename (default: %Y-%m-%d)
#   TEMPLATE_PAGES    - Number of blank pages (default: 5)
#   DRY_RUN           - Set to "true" to skip upload
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-5}"
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

# Create a blank PDF using ghostscript
create_blank_pdf() {
    local output_file="$1"
    local num_pages="$2"
    
    log "Generating $num_pages page blank PDF..."
    
    # Create PostScript that generates blank pages
    # reMarkable uses approximately 1404x1872 pixels at 226 DPI
    # which is roughly 445x594 points (Letter-ish size)
    # Using standard Letter (612x792) for compatibility
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
    
    log "PDF created: $output_file"
}

PDF_FILE="$TEMP_DIR/${FORMATTED_DATE}.pdf"
create_blank_pdf "$PDF_FILE" "$TEMPLATE_PAGES"

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
rmapi put "$PDF_FILE" "$REMARKABLE_FOLDER"

log "✓ Daily journal created successfully: $FORMATTED_DATE"
