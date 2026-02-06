#!/bin/bash
#
# cleanup-old-journals.sh
# Removes old journal notebooks that have not been annotated
#
# Scans all notebooks in the journal folder, downloads each one older than
# CLEANUP_KEEP_DAYS, and checks for handwriting annotations (.rm files in the
# document bundle). Notebooks without annotations are deleted.
#
# Environment variables:
#   REMARKABLE_FOLDER  - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT        - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED    - Set to "true" to enable cleanup (default: true)
#   CLEANUP_KEEP_DAYS  - Days to keep journals before cleanup eligibility (default: 1)
#   SIZE_THRESHOLD     - Fallback for non-ZIP downloads: files larger than this are kept (default: 50000)
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
CLEANUP_KEEP_DAYS="${CLEANUP_KEEP_DAYS:-1}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-25000}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"
}

# Exit early if cleanup is disabled
if [ "$CLEANUP_ENABLED" != "true" ]; then
    log "Cleanup disabled (CLEANUP_ENABLED=$CLEANUP_ENABLED)"
    exit 0
fi

TODAY_DATE=$(date +"$DATE_FORMAT")

# Calculate cutoff date - journals on or before this date are candidates
CUTOFF_TIMESTAMP=$(($(date +%s) - (CLEANUP_KEEP_DAYS * 86400)))
CUTOFF_DATE=$(date -d "@$CUTOFF_TIMESTAMP" +"$DATE_FORMAT" 2>/dev/null || date -r "$CUTOFF_TIMESTAMP" +"$DATE_FORMAT")

log "Scanning for unused journals on or before $CUTOFF_DATE"

# Create temp directory for operations
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Check if rmapi is authenticated
if ! rmapi ls / > /dev/null 2>&1; then
    log "ERROR: rmapi not authenticated, skipping cleanup"
    exit 0
fi

# List all documents in the journal folder
FOLDER_LISTING=$(rmapi ls "$REMARKABLE_FOLDER" 2>/dev/null || true)

if [ -z "$FOLDER_LISTING" ]; then
    log "No documents found in $REMARKABLE_FOLDER"
    exit 0
fi

# Save listing to file to avoid subshell variable scoping issues
echo "$FOLDER_LISTING" > "$TEMP_DIR/listing.txt"

# Check if a downloaded document has been annotated
# Returns 0 if annotated (keep), 1 if not annotated (delete)
check_has_annotations() {
    local file="$1"

    # Check if it's a ZIP file by magic bytes (ZIP starts with "PK")
    if [ "$(head -c2 "$file")" = "PK" ]; then
        # List ZIP contents and look for .rm annotation files
        # .rm files are Remarkable's annotation layers - one per page with handwriting
        if unzip -l "$file" 2>/dev/null | grep -q '\.rm$'; then
            return 0  # Has annotations
        else
            return 1  # No annotations
        fi
    fi

    # Fallback for non-ZIP files (e.g., plain PDF): use size threshold
    local file_size
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
    log "  Non-ZIP download ($file_size bytes), using size threshold ($SIZE_THRESHOLD)"

    if [ "$file_size" -gt "$SIZE_THRESHOLD" ]; then
        return 0  # Probably used
    else
        return 1  # Probably unused
    fi
}

# Track stats
CHECKED=0
DELETED=0
KEPT=0

while IFS= read -r line; do
    # Only process file entries, skip directories
    case "$line" in
        \[f\]*) ;;
        *) continue ;;
    esac

    # Extract document name (remove [f] prefix and whitespace)
    DOC_NAME="${line#\[f\]}"
    DOC_NAME="${DOC_NAME#"${DOC_NAME%%[![:space:]]*}"}"

    if [ -z "$DOC_NAME" ]; then
        continue
    fi

    # Extract date from document name (expects YYYY-MM-DD at the start)
    DOC_DATE=$(echo "$DOC_NAME" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)

    if [ -z "$DOC_DATE" ]; then
        continue
    fi

    # Skip today's journal
    if [ "$DOC_DATE" = "$TODAY_DATE" ]; then
        continue
    fi

    # Skip journals newer than cutoff (string comparison works for YYYY-MM-DD)
    if [ "$DOC_DATE" \> "$CUTOFF_DATE" ]; then
        continue
    fi

    CHECKED=$((CHECKED + 1))
    DOC_PATH="$REMARKABLE_FOLDER/$DOC_NAME"
    log "Checking: $DOC_NAME"

    # Download the journal to a temp subdirectory
    WORK_DIR="$TEMP_DIR/$DOC_DATE"
    mkdir -p "$WORK_DIR"

    if ! (cd "$WORK_DIR" && rmapi get "$DOC_PATH" > /dev/null 2>&1); then
        log "  Failed to download, skipping"
        rm -rf "$WORK_DIR"
        continue
    fi

    # Find the downloaded file
    DOWNLOADED_FILE=$(find "$WORK_DIR" -maxdepth 1 -type f \( -name "*.zip" -o -name "*.pdf" \) 2>/dev/null | head -1)

    if [ -z "$DOWNLOADED_FILE" ] || [ ! -f "$DOWNLOADED_FILE" ]; then
        log "  Downloaded file not found, skipping"
        rm -rf "$WORK_DIR"
        continue
    fi

    if check_has_annotations "$DOWNLOADED_FILE"; then
        log "  Journal has annotations, keeping"
        KEPT=$((KEPT + 1))
    else
        log "  Journal is unused, removing: $DOC_PATH"
        if rmapi rm "$DOC_PATH"; then
            log "  Removed: $DOC_NAME"
            DELETED=$((DELETED + 1))
        else
            log "  ERROR: Failed to remove"
        fi
    fi

    # Clean up work directory
    rm -rf "$WORK_DIR"
done < "$TEMP_DIR/listing.txt"

log "Cleanup complete: checked=$CHECKED deleted=$DELETED kept=$KEPT"
