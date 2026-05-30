#!/bin/bash
#
# cleanup-old-journals.sh
# Removes old journal notebooks that have not been annotated
#
# Scans all notebooks in the journal folder, downloads each one older than
# CLEANUP_KEEP_DAYS, and checks whether anything was written. Native notebooks
# always contain a .rm layer per page, so presence alone no longer signals use:
# an UNWRITTEN page's .rm is tiny (the empty scene skeleton, ~400 bytes), while
# writing on a page makes its .rm grow. A notebook is "used" if any page's .rm
# exceeds EMPTY_RM_MAX_BYTES; otherwise it is empty and gets deleted.
#
# Environment variables:
#   REMARKABLE_FOLDER  - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT        - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED    - Set to "true" to enable cleanup (default: true)
#   CLEANUP_KEEP_HOURS - Keep journals modified within this many hours (default: 48)
#   CLEANUP_KEEP_DAYS  - Legacy: used to derive KEEP_HOURS when HOURS is unset (default: 2)
#   EMPTY_RM_MAX_BYTES - A page .rm at/below this size counts as unwritten (default: 1000)
#   SIZE_THRESHOLD     - Fallback for non-ZIP downloads: files larger than this are kept (default: 25000)
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
CLEANUP_KEEP_DAYS="${CLEANUP_KEEP_DAYS:-2}"
CLEANUP_KEEP_HOURS="${CLEANUP_KEEP_HOURS:-$((CLEANUP_KEEP_DAYS * 24))}"
EMPTY_RM_MAX_BYTES="${EMPTY_RM_MAX_BYTES:-1000}"
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
NOW_EPOCH=$(date +%s)

# Convert an RFC3339 ModifiedClient timestamp (e.g. 2026-05-30T22:17:08Z, with
# optional fractional seconds) to epoch seconds using busybox date.
mc_to_epoch() {
    local mc="${1%%.*}"
    case "$mc" in *Z) ;; *) mc="${mc}Z" ;; esac
    date -u -D "%Y-%m-%dT%H:%M:%SZ" -d "$mc" +%s 2>/dev/null
}

log "Scanning for empty journals not modified in the last ${CLEANUP_KEEP_HOURS}h"

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

# Check if a downloaded document has been written on
# Returns 0 if written (keep), 1 if empty/unwritten (delete)
check_has_annotations() {
    local file="$1"

    # Native notebooks (and on-device-annotated PDFs) are ZIP bundles ("PK").
    if [ "$(head -c2 "$file")" = "PK" ]; then
        # Every page carries a .rm layer, so presence is not enough. Compare the
        # largest .rm layer against EMPTY_RM_MAX_BYTES: an unwritten page is just
        # the empty scene skeleton (~400 bytes); real strokes make it grow.
        local max_rm
        max_rm=$(unzip -l "$file" 2>/dev/null | awk '$NF ~ /\.rm$/ {print $1}' | sort -n | tail -1)

        if [ -z "$max_rm" ]; then
            return 1  # No .rm layers at all -> nothing written
        fi

        log "  Largest .rm layer: ${max_rm} bytes (empty threshold: ${EMPTY_RM_MAX_BYTES})"
        if [ "$max_rm" -gt "$EMPTY_RM_MAX_BYTES" ]; then
            return 0  # Has writing
        else
            return 1  # All pages blank
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

    DOC_PATH="$REMARKABLE_FOLDER/$DOC_NAME"

    # Recency gate: keep journals modified within CLEANUP_KEEP_HOURS, using the
    # cloud's ModifiedClient (more accurate than the name date - a journal
    # written in days after it was created stays recent). Skipping these also
    # avoids downloading them. Falls through to the size check if stat fails.
    MC=$(rmapi stat "$DOC_PATH" 2>/dev/null | jq -r '.ModifiedClient // empty' 2>/dev/null || true)
    if [ -n "$MC" ]; then
        MC_EPOCH=$(mc_to_epoch "$MC")
        if [ -n "$MC_EPOCH" ]; then
            AGE_HOURS=$(( (NOW_EPOCH - MC_EPOCH) / 3600 ))
            if [ "$AGE_HOURS" -lt "$CLEANUP_KEEP_HOURS" ]; then
                log "Keeping (modified ${AGE_HOURS}h ago < ${CLEANUP_KEEP_HOURS}h): $DOC_NAME"
                KEPT=$((KEPT + 1))
                continue
            fi
        fi
    fi

    CHECKED=$((CHECKED + 1))
    log "Checking: $DOC_NAME (stale, verifying contents)"

    # Download the journal to a temp subdirectory
    WORK_DIR="$TEMP_DIR/$DOC_DATE"
    mkdir -p "$WORK_DIR"

    GET_OUTPUT=$(cd "$WORK_DIR" && rmapi get "$DOC_PATH" 2>&1) || true
    GET_EXIT=$?
    log "  rmapi get exit=$GET_EXIT output: $GET_OUTPUT"

    # List all files in work directory for debugging
    WORK_FILES=$(find "$WORK_DIR" -type f 2>/dev/null)
    if [ -n "$WORK_FILES" ]; then
        log "  Files downloaded:"
        echo "$WORK_FILES" | while IFS= read -r f; do
            FILE_SIZE=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
            FILE_MAGIC=$(head -c4 "$f" 2>/dev/null | od -A n -t x1 | tr -d ' ')
            log "    $(basename "$f") ($FILE_SIZE bytes, magic: $FILE_MAGIC)"
        done
    else
        log "  No files found in $WORK_DIR"
        rm -rf "$WORK_DIR"
        continue
    fi

    # Find the downloaded file (rmapi may save without an extension)
    DOWNLOADED_FILE=$(find "$WORK_DIR" -maxdepth 1 -type f 2>/dev/null | head -1)

    if [ -z "$DOWNLOADED_FILE" ] || [ ! -f "$DOWNLOADED_FILE" ]; then
        log "  Downloaded file not found, skipping"
        rm -rf "$WORK_DIR"
        continue
    fi

    if check_has_annotations "$DOWNLOADED_FILE"; then
        log "  Journal has writing, keeping"
        KEPT=$((KEPT + 1))
    else
        log "  Journal is empty/unwritten, removing: $DOC_PATH"
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
