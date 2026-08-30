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
# Rate-limit budget. Every rmapi invocation is a fresh process that re-exchanges
# the device token for a user token, and reMarkable's auth endpoint starts
# returning HTTP 429 after a handful in quick succession. So this pass:
#   * reads ModifiedClient for the WHOLE folder from one `rmapi -json ls` call
#     instead of one `rmapi stat` per document,
#   * caps downloads per pass at CLEANUP_MAX_DOCS,
#   * spaces the remaining calls by CLEANUP_API_DELAY_SECONDS, and
#   * aborts the whole pass the moment it sees a 429 rather than grinding on.
#
# Everything here also fails CLOSED: any document we cannot positively prove is
# both in-window and empty is kept. A failed metadata read or a failed download
# must never make a journal a deletion candidate.
#
# Environment variables:
#   REMARKABLE_FOLDER  - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT        - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED    - Set to "true" to enable cleanup (default: true)
#   CLEANUP_KEEP_HOURS - Only inspect journals modified within this many hours;
#                        anything older is left alone (default: 48)
#   CLEANUP_KEEP_DAYS  - Legacy: used to derive KEEP_HOURS when HOURS is unset (default: 2)
#   EMPTY_RM_MAX_BYTES - A page .rm at/below this size counts as unwritten (default: 1000)
#   SIZE_THRESHOLD     - Fallback for non-ZIP downloads: files larger than this are kept (default: 25000)
#   CLEANUP_DRY_RUN    - Set to "true" to log deletions without removing anything (default: false)
#   CLEANUP_MAX_DOCS   - Most journals to download in a single pass (default: 5)
#   CLEANUP_API_DELAY_SECONDS
#                      - Seconds to wait between rmapi calls in the per-document
#                        loop, to stay under the auth rate limit (default: 2)
#   CLEANUP_CACHE      - Path to a persistent tsv ({name}\t{ModifiedClient}) of
#                        journals we already verified as non-empty; reused across
#                        runs to skip re-downloading unchanged journals (default:
#                        /app/.config/rmapi/cleanup-cache.tsv, alongside rmapi's
#                        own config so it lives in the existing persistent volume)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
CLEANUP_KEEP_DAYS="${CLEANUP_KEEP_DAYS:-2}"
CLEANUP_KEEP_HOURS="${CLEANUP_KEEP_HOURS:-$((CLEANUP_KEEP_DAYS * 24))}"
EMPTY_RM_MAX_BYTES="${EMPTY_RM_MAX_BYTES:-1000}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-25000}"
CLEANUP_DRY_RUN="${CLEANUP_DRY_RUN:-false}"
CLEANUP_MAX_DOCS="${CLEANUP_MAX_DOCS:-5}"
CLEANUP_API_DELAY_SECONDS="${CLEANUP_API_DELAY_SECONDS:-2}"
CLEANUP_CACHE="${CLEANUP_CACHE:-/app/.config/rmapi/cleanup-cache.tsv}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"
}

# shellcheck source=rmapi-health.sh
. "$SCRIPT_DIR/rmapi-health.sh"

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

# Track stats (declared before abort_rate_limited, which reports them)
CHECKED=0
DELETED=0
KEPT=0

# A 429 means we have already spent our token-exchange budget. Continuing would
# only deepen the limit and, worse, produce failed downloads that a fail-open
# check could misread as "empty". Stop the pass; the next run picks it up.
# Exits 0 because a deferred cleanup is not a container failure.
abort_rate_limited() {
    log "ABORTING pass: reMarkable returned HTTP 429 (rate limited) on: ${1:-rmapi}"
    log "  This is NOT a token problem. Each rmapi call re-exchanges the device"
    log "  token, so continuing would only deepen the limit."
    log "  Cleanup resumes on the next scheduled run."
    log "Cleanup aborted: checked=$CHECKED deleted=$DELETED kept=$KEPT"
    exit 0
}

# Space out calls in the per-document loop so a window with several candidates
# does not burst the auth endpoint.
api_pause() {
    [ "$CLEANUP_API_DELAY_SECONDS" -gt 0 ] 2>/dev/null || return 0
    sleep "$CLEANUP_API_DELAY_SECONDS"
}

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

# Health check. Skipped when the entrypoint already verified health for this
# cycle (RMAPI_HEALTH_VERIFIED), so we do not spend a token exchange twice.
HEALTH_RC=0
rmapi_require_health || HEALTH_RC=$?
if [ "$HEALTH_RC" -ne 0 ]; then
    rmapi_explain_health "$HEALTH_RC"
    log "Skipping cleanup (rmapi health check failed with code $HEALTH_RC)"
    exit 0
fi

# One listing for the whole folder, with metadata.
#
# This replaces the old `rmapi stat` per document. With 58 notebooks that was
# 58 processes, 58 token exchanges, and a guaranteed 429 within seconds — which
# then took the journal creation that ran afterwards down with it. `rmapi -json
# ls` returns name + modifiedClient for every entry in a single call.
LS_EXIT=0
LISTING_JSON=$(rmapi -json ls "$REMARKABLE_FOLDER" 2>"$TEMP_DIR/ls.err") || LS_EXIT=$?
LS_ERR=$(cat "$TEMP_DIR/ls.err" 2>/dev/null || true)

if [ "$LS_EXIT" -ne 0 ]; then
    if rmapi_is_rate_limited "$LS_ERR$LISTING_JSON"; then
        abort_rate_limited "rmapi -json ls \"$REMARKABLE_FOLDER\""
    fi
    log "Could not list $REMARKABLE_FOLDER (exit=$LS_EXIT): $LS_ERR"
    log "Skipping cleanup"
    exit 0
fi

if ! echo "$LISTING_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    # An rmapi without the -json flag (or an unexpected output shape). The
    # recency gate needs ModifiedClient to prove a journal is in-window, and
    # this pass fails closed, so there is nothing safe left to do.
    log "ERROR: 'rmapi -json ls' did not return a JSON array. Cleanup needs it to"
    log "       read ModifiedClient for the whole folder in one call. Rebuild the"
    log "       image so rmapi is new enough to support -json."
    log "       stderr: $LS_ERR"
    # If -json ever goes away, the other single-handshake option is to pipe N
    # stat commands into one interactive rmapi session (`rmapi -ni` with the
    # commands on stdin). Measured at 59 stats, 1 handshake, 0 429s. Same win,
    # more output parsing, so it is the fallback rather than the default.
    exit 0
fi

# name<TAB>modifiedClient, documents only.
#
# The type filter is load-bearing: the old parser keyed off the `[f]` prefix in
# `rmapi ls` output, so folders excluded themselves. Here a subfolder arrives as
# a CollectionType entry and would otherwise be treated as a journal.
#
# The field is lowercase `modifiedClient` — `rmapi -json ls` marshals a NodeJSON
# with explicit json tags, while `rmapi stat` marshals the bare Go struct and so
# emits capitalised `ModifiedClient`. The capitalised spelling is accepted as a
# fallback only so a future shape change degrades into "keep working" rather
# than "every document yields an empty MC, the fail-closed gate skips them all,
# and cleanup silently becomes a permanent no-op".
echo "$LISTING_JSON" \
    | jq -r '.[]
             | select((.type // .Type) == "DocumentType")
             | [(.name // .Name), (.modifiedClient // .ModifiedClient // "")]
             | @tsv' \
    > "$TEMP_DIR/listing.tsv"

if [ ! -s "$TEMP_DIR/listing.tsv" ]; then
    log "No documents found in $REMARKABLE_FOLDER"
    exit 0
fi

log "Listed $(wc -l < "$TEMP_DIR/listing.tsv" | tr -d ' ') documents in one call"

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

while IFS=$'\t' read -r DOC_NAME MC; do
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
    # and is left alone — no download, no inspection, never deleted.
    #
    # The gate fails CLOSED. A missing or unparseable ModifiedClient means we
    # cannot prove the journal is in-window, so we skip it. The old code only
    # applied the gate `if [ -n "$MC" ]`, which meant a failed stat let a
    # settled January journal fall through to a full download and become a
    # deletion candidate — exactly the wrong response to an API failure.
    if [ -z "$MC" ]; then
        log "Skipping (no ModifiedClient in listing, cannot prove it is in-window): $DOC_NAME"
        KEPT=$((KEPT + 1))
        continue
    fi

    MC_EPOCH=$(mc_to_epoch "$MC")
    if [ -z "$MC_EPOCH" ]; then
        log "Skipping (unparseable ModifiedClient '$MC'): $DOC_NAME"
        KEPT=$((KEPT + 1))
        continue
    fi

    AGE_HOURS=$(( (NOW_EPOCH - MC_EPOCH) / 3600 ))
    if [ "$AGE_HOURS" -ge "$CLEANUP_KEEP_HOURS" ]; then
        log "Skipping (settled, modified ${AGE_HOURS}h ago >= ${CLEANUP_KEEP_HOURS}h): $DOC_NAME"
        KEPT=$((KEPT + 1))
        continue
    fi

    # Persistent-cache short-circuit: if we already verified this exact
    # (name, ModifiedClient) as non-empty, skip the download.
    CACHED_MC=$(cache_lookup_mc "$DOC_NAME" 2>/dev/null || true)
    if [ -n "$CACHED_MC" ] && [ "$CACHED_MC" = "$MC" ]; then
        log "Keeping (cached non-empty, ModifiedClient unchanged): $DOC_NAME"
        KEPT=$((KEPT + 1))
        continue
    fi

    # Hard cap on downloads per pass. The recency window should already keep
    # this to a journal or two, but a clock jump or a bulk re-sync could make
    # everything look in-window at once, and cleanup must never be able to
    # spend the whole rate budget that journal creation also needs.
    if [ "$CHECKED" -ge "$CLEANUP_MAX_DOCS" ]; then
        log "Reached CLEANUP_MAX_DOCS=$CLEANUP_MAX_DOCS for this pass, leaving the rest for the next run"
        break
    fi

    CHECKED=$((CHECKED + 1))
    log "Checking: $DOC_NAME (in window, verifying contents)"

    # Download the journal to a temp subdirectory
    WORK_DIR="$TEMP_DIR/$DOC_DATE"
    mkdir -p "$WORK_DIR"

    api_pause
    GET_EXIT=0
    GET_OUTPUT=$(cd "$WORK_DIR" && rmapi get "$DOC_PATH" 2>&1) || GET_EXIT=$?

    # GET_EXIT is rmapi's real status. It used to be captured after a `|| true`,
    # so it read 0 even for `ERROR: ... status 429`, and the script could not
    # tell "the API refused us" from "this journal is genuinely empty".
    if [ "$GET_EXIT" -ne 0 ]; then
        log "  Download FAILED (exit=$GET_EXIT): $GET_OUTPUT"
        if rmapi_is_rate_limited "$GET_OUTPUT"; then
            rm -rf "$WORK_DIR"
            abort_rate_limited "rmapi get \"$DOC_PATH\""
        fi
        log "  Cannot verify contents, keeping: $DOC_NAME"
        KEPT=$((KEPT + 1))
        rm -rf "$WORK_DIR"
        continue
    fi
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
        log "  rmapi reported success but produced no files, keeping: $DOC_NAME"
        KEPT=$((KEPT + 1))
        rm -rf "$WORK_DIR"
        continue
    fi

    # Find the downloaded file (rmapi may save without an extension)
    DOWNLOADED_FILE=$(find "$WORK_DIR" -maxdepth 1 -type f 2>/dev/null | head -1)

    if [ -z "$DOWNLOADED_FILE" ] || [ ! -f "$DOWNLOADED_FILE" ]; then
        log "  Downloaded file not found, keeping: $DOC_NAME"
        KEPT=$((KEPT + 1))
        rm -rf "$WORK_DIR"
        continue
    fi

    if check_has_annotations "$DOWNLOADED_FILE"; then
        log "  Journal has writing, keeping"
        cache_record "$DOC_NAME" "$MC"
        KEPT=$((KEPT + 1))
    elif [ "$CLEANUP_DRY_RUN" = "true" ]; then
        log "  DRY RUN: would remove empty journal: $DOC_PATH"
        DELETED=$((DELETED + 1))
    else
        log "  Journal is empty/unwritten, removing: $DOC_PATH"
        api_pause
        RM_EXIT=0
        RM_OUTPUT=$(rmapi rm "$DOC_PATH" 2>&1) || RM_EXIT=$?
        if [ "$RM_EXIT" -eq 0 ]; then
            log "  Removed: $DOC_NAME"
            cache_forget "$DOC_NAME"
            DELETED=$((DELETED + 1))
        else
            log "  ERROR: Failed to remove (exit=$RM_EXIT)"
            rmapi_explain_write_failure "$RM_OUTPUT" "delete"
            if rmapi_is_rate_limited "$RM_OUTPUT"; then
                rm -rf "$WORK_DIR"
                abort_rate_limited "rmapi rm \"$DOC_PATH\""
            fi
        fi
    fi

    # Clean up work directory
    rm -rf "$WORK_DIR"
done < "$TEMP_DIR/listing.tsv"

if [ "$CLEANUP_DRY_RUN" = "true" ]; then
    log "Cleanup complete (DRY RUN): checked=$CHECKED would-delete=$DELETED kept=$KEPT"
else
    log "Cleanup complete: checked=$CHECKED deleted=$DELETED kept=$KEPT"
fi
