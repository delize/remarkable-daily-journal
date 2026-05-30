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
#   CLEANUP_DRY_RUN    - Set to "true" to log deletions without removing anything (default: false)
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
CLEANUP_DRY_RUN="${CLEANUP_DRY_RUN:-false}"

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

# Convert an RFC3339 UTC ModifiedClient timestamp (e.g. 2026-05-30T22:17:08Z,
# with optional fractional seconds) to epoch seconds. Pure shell arithmetic so
# it does not depend on busybox/GNU date flag support. Prints nothing on a
# malformed input. Uses Howard Hinnant's days_from_civil algorithm.
mc_to_epoch() {
    local s="${1%%.*}"          # drop any fractional seconds
    s="${s%Z}"                  # drop trailing Z
    # Expect YYYY-MM-DDTHH:MM:SS
    case "$s" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
        *) return 0 ;;
    esac
    local Y=$((10#${s:0:4})) Mo=$((10#${s:5:2})) D=$((10#${s:8:2}))
    local h=$((10#${s:11:2})) mi=$((10#${s:14:2})) se=$((10#${s:17:2}))

    local y=$Y
    [ "$Mo" -le 2 ] && y=$((y - 1))
    local era yoe doy doe days
    if [ "$y" -ge 0 ]; then era=$((y / 400)); else era=$(((y - 399) / 400)); fi
    yoe=$((y - era * 400))
    if [ "$Mo" -gt 2 ]; then doy=$(((153 * (Mo - 3) + 2) / 5 + D - 1)); else doy=$(((153 * (Mo + 9) + 2) / 5 + D - 1)); fi
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    days=$((era * 146097 + doe - 719468))
    echo $((days * 86400 + h * 3600 + mi * 60 + se))
}

log "Scanning for empty journals not modified in the last ${CLEANUP_KEEP_HOURS}h"
[ "$CLEANUP_DRY_RUN" = "true" ] && log "DRY RUN enabled: nothing will be deleted"

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
    elif [ "$CLEANUP_DRY_RUN" = "true" ]; then
        log "  DRY RUN: would remove empty journal: $DOC_PATH"
        DELETED=$((DELETED + 1))
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

if [ "$CLEANUP_DRY_RUN" = "true" ]; then
    log "Cleanup complete (DRY RUN): checked=$CHECKED would-delete=$DELETED kept=$KEPT"
else
    log "Cleanup complete: checked=$CHECKED deleted=$DELETED kept=$KEPT"
fi
