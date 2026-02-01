#!/bin/bash
#
# create-daily-note.sh
# Creates a dated daily journal notebook and uploads to reMarkable via rmapi
#
# Environment variables:
#   REMARKABLE_FOLDER - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT       - Date format for filename (default: %Y-%m-%d)
#   TEMPLATE_PAGES    - Number of blank pages (default: 5)
#   TEMPLATE_STYLE    - Page style: blank, lined, grid (default: blank)
#   LINE_SPACING      - Line spacing in points for lined/grid (default: 24)
#   LINE_COLOR        - Line color as "R G B" values 0-1 (default: 0.85 0.85 0.85)
#   DRY_RUN           - Set to "true" to skip upload
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-5}"
TEMPLATE_STYLE="${TEMPLATE_STYLE:-blank}"
LINE_SPACING="${LINE_SPACING:-24}"
LINE_COLOR="${LINE_COLOR:-0.85 0.85 0.85}"
DRY_RUN="${DRY_RUN:-false}"

# Page dimensions (Letter size in points)
PAGE_WIDTH=612
PAGE_HEIGHT=792
MARGIN=36  # 0.5 inch margin

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

# Create PDF using ghostscript with specified template style
create_pdf() {
    local output_file="$1"
    local num_pages="$2"
    local style="$3"

    log "Generating $num_pages page $style PDF..."

    # Generate PostScript based on template style
    case "$style" in
        lined)
            cat > "$TEMP_DIR/template.ps" << EOF
%!PS-Adobe-3.0
/drawlines {
    $LINE_COLOR setrgbcolor
    0.5 setlinewidth
    $MARGIN $LINE_SPACING $PAGE_HEIGHT $MARGIN sub {
        dup $MARGIN exch moveto
        $PAGE_WIDTH $MARGIN sub exch lineto
        stroke
    } for
} def

1 1 $num_pages {
    drawlines
    showpage
} for
EOF
            ;;
        grid)
            cat > "$TEMP_DIR/template.ps" << EOF
%!PS-Adobe-3.0
/drawgrid {
    $LINE_COLOR setrgbcolor
    0.5 setlinewidth
    % Horizontal lines
    $MARGIN $LINE_SPACING $PAGE_HEIGHT $MARGIN sub {
        dup $MARGIN exch moveto
        $PAGE_WIDTH $MARGIN sub exch lineto
        stroke
    } for
    % Vertical lines
    $MARGIN $LINE_SPACING $PAGE_WIDTH $MARGIN sub {
        dup $MARGIN moveto
        dup $PAGE_HEIGHT $MARGIN sub lineto
        stroke
    } for
} def

1 1 $num_pages {
    drawgrid
    showpage
} for
EOF
            ;;
        *)  # blank
            cat > "$TEMP_DIR/template.ps" << EOF
%!PS-Adobe-3.0
1 1 $num_pages {
    showpage
} for
EOF
            ;;
    esac

    gs -sDEVICE=pdfwrite \
       -dNOPAUSE \
       -dBATCH \
       -dQUIET \
       -dDEVICEWIDTHPOINTS=$PAGE_WIDTH \
       -dDEVICEHEIGHTPOINTS=$PAGE_HEIGHT \
       -sOutputFile="$output_file" \
       "$TEMP_DIR/template.ps"

    log "PDF created: $output_file"
}

PDF_FILE="$TEMP_DIR/${FORMATTED_DATE}.pdf"
create_pdf "$PDF_FILE" "$TEMPLATE_PAGES" "$TEMPLATE_STYLE"

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
