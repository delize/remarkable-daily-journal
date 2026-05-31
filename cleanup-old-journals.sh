#!/bin/bash
#
# cleanup-old-journals.sh
# Removes recently-generated daily journals that never got written in.
#
# Policy: a journal is only a deletion candidate while it is YOUNGER than
# CLEANUP_KEEP_HOURS (default 48h). Anything older than the window is
# considered settled and is skipped entirely — no download, no inspection,
# never deleted. This guarantees that once a daily journal survives past the
# window it stays forever, and the cleanup pass only touches the most recent
# auto-generated empty ones.
#
# For each in-window journal we download the bundle and check whether any
# page was written on. Native notebooks always contain a .rm layer per page,
# so presence alone is not enough: an UNWRITTEN page's .rm is tiny (the empty
# scene skeleton, ~400 bytes), while writing on a page makes it grow. A page
# .rm larger than EMPTY_RM_MAX_BYTES counts as written; otherwise the
# notebook is empty and gets deleted.
#
# Environment variables:
#   REMARKABLE_FOLDER  - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT        - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED    - Set to "true" to enable cleanup (default: true)
#   CLEANUP_KEEP_HOURS - Only inspect journals modified within this many hours;
#                        anything older is left alone (default: 48)
#   CLEANUP_KEEP_DAYS  - Legacy: used to derive KEEP_HOURS when HOURS is unset (default: 2)
#   EMPTY_RM_MAX_BYTES - A page .rm at/below this size counts as unwritten (default: 1000)
#   EMPTY_BUNDLE_MAX_BYTES - If the cloud's sizeInBytes is above this, skip the
#                        download and treat the journal as written-on (default: 50000)
#   SIZE_THRESHOLD     - Fallback for non-ZIP downloads: files larger than this are kept (default: 25000)
#   CLEANUP_DRY_RUN    - Set to "true" to log deletions without removing anything (default: false)
#   CLEANUP_CACHE      - Path to a persistent tsv ({name}\t{ModifiedClient}) of
#                        journals we already verified as non-empty; reused across
#                        runs to skip re-downloading unchanged journals (default:
#                        /app/.config/rmapi/cleanup-cache.tsv, alongside rmapi's
#                        own config so it lives in the existing persistent volume)
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
CLEANUP_KEEP_DAYS="${CLEANUP_KEEP_DAYS:-2}"
CLEANUP_KEEP_HOURS="${CLEANUP_KEEP_HOURS:-$((CLEANUP_KEEP_DAYS * 24))}"
EMPTY_RM_MAX_BYTES="${EMPTY_RM_MAX_BYTES:-1000}"
EMPTY_BUNDLE_MAX_BYTES="${EMPTY_BUNDLE_MAX_BYTES:-50000}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-25000}"
CLEANUP_DRY_RUN="${CLEANUP_DRY_RUN:-false}"
CLEANUP_CACHE="${CLEANUP_CACHE:-/app/.config/rmapi/cleanup-cache.tsv}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"
}

# Persistent cache of journals we already verified as non-empty.
# Format: one line per journal, "<name>\t<ModifiedClient>".
# A hit on (name, ModifiedClient) means: we downloaded this before, it had
# writing, and the cloud copy hasn't changed since — so skip the download.
cache_lookup_mc() {
    [ -f "$CLEANUP_CACHE" ] || return 1
    awk -F'\t' -v n="$1" '$1==n {print $2; found=1; exit} END{exit !found}' "$CLEANUP_CACHE"
}

cache_record() {
    local name="$1" mc="$2"
    [ -n "$mc" ] || return 0
    mkdir -p "$(dirname "$CLEANUP_CACHE")" 2>/dev/null || true
    if [ -f "$CLEANUP_CACHE" ]; then
        awk -F'\t' -v n="$name" '$1!=n' "$CLEANUP_CACHE" > "$CLEANUP_CACHE.tmp" || true
        mv "$CLEANUP_CACHE.tmp" "$CLEANUP_CACHE"
    fi
    printf '%s\t%s\n' "$name" "$mc" >> "$CLEANUP_CACHE"
}

cache_forget() {
    local name="$1"
    [ -f "$CLEANUP_CACHE" ] || return 0
    awk -F'\t' -v n="$name" '$1!=n' "$CLEANUP_CACHE" > "$CLEANUP_CACHE.tmp" || true
    mv "$CLEANUP_CACHE.tmp" "$CLEANUP_CACHE"
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

log "Scanning for empty journals modified within the last ${CLEANUP_KEEP_HOURS}h (older journals are left alone)"
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

    # Extract the ISO date from the document name (anywhere — the name may have
    # a custom prefix/suffix via JOURNAL_NAME_FORMAT, e.g. "Journal 2026-05-31").
    DOC_DATE=$(echo "$DOC_NAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)

    if [ -z "$DOC_DATE" ]; then
        continue
    fi

    # Skip today's journal
    if [ "$DOC_DATE" = "$TODAY_DATE" ]; then
        continue
    fi

    DOC_PATH="$REMARKABLE_FOLDER/$DOC_NAME"

    # Recency gate (flipped): journals are only deletion candidates while they
    # are YOUNGER than CLEANUP_KEEP_HOURS. Anything older is considered settled
    # and is left alone — no download, no inspection, never deleted. This caps
    # work at a couple of journals per pass and guarantees that once a journal
    # survives past the window it stays forever. Falls through to inspection
    # only if rmapi stat returned a parseable ModifiedClient.
    STAT_JSON=$(rmapi stat "$DOC_PATH" 2>/dev/null || true)
    MC=$(echo "$STAT_JSON" | jq -r '.ModifiedClient // empty' 2>/dev/null || true)
    SIZE_IN_BYTES=$(echo "$STAT_JSON" | jq -r '.sizeInBytes // .SizeInBytes // empty' 2>/dev/null || true)
    if [ -n "$MC" ]; then
        MC_EPOCH=$(mc_to_epoch "$MC")
        if [ -n "$MC_EPOCH" ]; then
            AGE_HOURS=$(( (NOW_EPOCH - MC_EPOCH) / 3600 ))
            if [ "$AGE_HOURS" -ge "$CLEANUP_KEEP_HOURS" ]; then
                log "Skipping (settled, modified ${AGE_HOURS}h ago >= ${CLEANUP_KEEP_HOURS}h): $DOC_NAME"
                KEPT=$((KEPT + 1))
                continue
            fi
        fi
    fi

    # Persistent-cache short-circuit: if we already verified this exact
    # (name, ModifiedClient) as non-empty, skip the download.
    if [ -n "$MC" ]; then
        CACHED_MC=$(cache_lookup_mc "$DOC_NAME" 2>/dev/null || true)
        if [ -n "$CACHED_MC" ] && [ "$CACHED_MC" = "$MC" ]; then
            log "Keeping (cached non-empty, ModifiedClient unchanged): $DOC_NAME"
            KEPT=$((KEPT + 1))
            continue
        fi
    fi

    # Cloud-size short-circuit: the empty generated bundle is ~6KB; any real
    # ink pushes the bundle well past EMPTY_BUNDLE_MAX_BYTES. If the cloud
    # already reports a big bundle, treat it as written-on and skip the
    # download. Only trust this if we also have a ModifiedClient to cache
    # against, so we don't re-skip if the cloud copy later changes.
    if [ -n "$SIZE_IN_BYTES" ] && [ "$SIZE_IN_BYTES" -gt "$EMPTY_BUNDLE_MAX_BYTES" ] 2>/dev/null; then
        log "Keeping (cloud size ${SIZE_IN_BYTES} > ${EMPTY_BUNDLE_MAX_BYTES}, written-on): $DOC_NAME"
        [ -n "$MC" ] && cache_record "$DOC_NAME" "$MC"
        KEPT=$((KEPT + 1))
        continue
    fi

    CHECKED=$((CHECKED + 1))
    log "Checking: $DOC_NAME (in window, verifying contents)"

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
        [ -n "$MC" ] && cache_record "$DOC_NAME" "$MC"
        KEPT=$((KEPT + 1))
    elif [ "$CLEANUP_DRY_RUN" = "true" ]; then
        log "  DRY RUN: would remove empty journal: $DOC_PATH"
        DELETED=$((DELETED + 1))
    else
        log "  Journal is empty/unwritten, removing: $DOC_PATH"
        if rmapi rm "$DOC_PATH"; then
            log "  Removed: $DOC_NAME"
            cache_forget "$DOC_NAME"
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
