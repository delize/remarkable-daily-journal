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
#   JOURNAL_NAME      - Literal name override. If set, used verbatim and the
#                       strftime format is ignored. Handy for ad-hoc test
#                       uploads (e.g. JOURNAL_NAME=template-fix-test).
#                       A positional date argument still wins over this.
#   TEMPLATE_PAGES    - Number of pages (default: 1). Pages added on the device
#                       inherit the current page's template automatically.
#   TEMPLATE_STYLE    - Template: blank, lined, grid, checklist, or any raw
#                       reMarkable template name (default: lined -> "P Lines medium")
#   TEMPLATE_PDF      - Optional: path to a PDF to use as the page background
#                       instead of TEMPLATE_STYLE. Mutually exclusive with
#                       TEMPLATE_DOC. Produces a plain PDF upload by default
#                       (proven-safe path; see generate-native-journal.sh's
#                       header for why). See also README.
#   TEMPLATE_DOC      - Optional: cloud path of an existing PDF-backed document
#                       to reuse as the page background. Mutually exclusive
#                       with TEMPLATE_PDF. See generate-native-journal.sh / README.
#   TEMPLATE_PDF_NATIVE_EXPERIMENTAL
#                     - "true" to build an experimental native .rmdoc bundle
#                       for TEMPLATE_PDF/TEMPLATE_DOC instead of a plain PDF
#                       upload. NOT independently verified on real hardware —
#                       see docs/decisions/0001-custom-pdf-page-backgrounds.md.
#   AUTHOR_UUID       - Optional canonical UUID stamped into every page so the
#                       device sees these journals as authored by you. Default:
#                       a fresh random UUID per journal. See README for how to
#                       extract your account's UUID from one of your existing
#                       notebooks.
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
TEMPLATE_PDF_NATIVE_EXPERIMENTAL="${TEMPLATE_PDF_NATIVE_EXPERIMENTAL:-false}"
DRY_RUN="${DRY_RUN:-false}"

# Portable date parser: works with both GNU coreutils `date -d` (Alpine, the
# container's runtime) and BSD `date -j -f` (macOS, where tests run).
# Usage: parse_date "YYYY-MM-DD" "+fmt"
parse_date() {
    local day="$1" fmt="$2"
    if date -d "$day" "$fmt" >/dev/null 2>&1; then
        date -d "$day" "$fmt"
    else
        date -j -f "%Y-%m-%d" "$day" "$fmt"
    fi
}

# Same idea, with an explicit "noon UTC of that day" instant so the result
# doesn't drift with the caller's TZ.
parse_date_noon_utc_epoch() {
    local day="$1"
    if date -d "$day 12:00:00 UTC" +%s >/dev/null 2>&1; then
        date -d "$day 12:00:00 UTC" +%s
    else
        date -j -u -f "%Y-%m-%d %H:%M:%S" "$day 12:00:00" +%s
    fi
}

# Notebook name. Priority: positional date arg > JOURNAL_NAME env (literal
# override, for ad-hoc test uploads) > strftime of today via JOURNAL_NAME_FORMAT.
# Backfill: when a date arg is given, also stamp createdTime/lastModified at
# noon UTC of that date so the device's "Created" date matches the name.
if [ -n "${1:-}" ]; then
    JOURNAL_NAME=$(parse_date "$1" +"$JOURNAL_NAME_FORMAT")
    CREATED_TIME_MS="$(parse_date_noon_utc_epoch "$1")000"
    export CREATED_TIME_MS
elif [ -z "${JOURNAL_NAME:-}" ]; then
    JOURNAL_NAME=$(date +"$JOURNAL_NAME_FORMAT")
fi

# Temp directory for working files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# shellcheck source=rmapi-health.sh
. "$SCRIPT_DIR/rmapi-health.sh"

log "Creating daily journal: $JOURNAL_NAME"
log "Target folder: $REMARKABLE_FOLDER"
PDF_SOURCE_ACTIVE=false
if [ -n "${TEMPLATE_PDF:-}" ] || [ -n "${TEMPLATE_DOC:-}" ]; then
    PDF_SOURCE_ACTIVE=true
fi
if [ -n "${TEMPLATE_PDF:-}" ]; then
    log "Template: PDF background ($TEMPLATE_PDF), native_experimental=$TEMPLATE_PDF_NATIVE_EXPERIMENTAL"
elif [ -n "${TEMPLATE_DOC:-}" ]; then
    log "Template: PDF background (cloud doc: $TEMPLATE_DOC), native_experimental=$TEMPLATE_PDF_NATIVE_EXPERIMENTAL"
else
    log "Template: $TEMPLATE_STYLE, pages: $TEMPLATE_PAGES"
fi

# Build the native notebook. rmapi put uses the file's basename as the cloud
# visibleName, so name the output after JOURNAL_NAME (slashes → dashes so an
# unusual JOURNAL_NAME_FORMAT can't escape the temp dir). A PDF source without
# the experimental flag produces a plain .pdf (rmapi dispatches upload
# behavior from the file extension); everything else produces a .rmdoc bundle.
SAFE_NAME="${JOURNAL_NAME//\//-}"
if [ "$PDF_SOURCE_ACTIVE" = "true" ] && [ "$TEMPLATE_PDF_NATIVE_EXPERIMENTAL" != "true" ]; then
    RMDOC_FILE="$TEMP_DIR/$SAFE_NAME.pdf"
else
    RMDOC_FILE="$TEMP_DIR/$SAFE_NAME.rmdoc"
fi
JOURNAL_NAME="$JOURNAL_NAME" \
TEMPLATE_STYLE="$TEMPLATE_STYLE" \
TEMPLATE_PAGES="$TEMPLATE_PAGES" \
TEMPLATE_PDF_NATIVE_EXPERIMENTAL="$TEMPLATE_PDF_NATIVE_EXPERIMENTAL" \
OUTPUT_FILE="$RMDOC_FILE" \
    "$SCRIPT_DIR/generate-native-journal.sh"

if [ "$DRY_RUN" = "true" ]; then
    log "DRY RUN: Would upload '$JOURNAL_NAME' to $REMARKABLE_FOLDER"
    exit 0
fi

# Check rmapi health. Every failure used to be reported as "not authenticated",
# which sent people re-authenticating over a cloud 4xx or a rate limit. The
# shared helper classifies the failure instead (see rmapi-health.sh), and it
# skips the check entirely when the entrypoint already verified health for this
# cycle, so we do not spend a second token exchange against the same limiter.
HEALTH_RC=0
rmapi_require_health || HEALTH_RC=$?
if [ "$HEALTH_RC" -ne 0 ]; then
    rmapi_explain_health "$HEALTH_RC"
    log "ERROR: cannot reach the reMarkable cloud, not creating '$JOURNAL_NAME'"
    exit 1
fi

# List the target folder. This doubles as the duplicate check and as the
# folder-exists check, so the steady-state path is one call rather than an
# unconditional mkdir followed by an ls.
LS_EXIT=0
FOLDER_LISTING=$(rmapi ls "$REMARKABLE_FOLDER" 2>&1) || LS_EXIT=$?

if [ "$LS_EXIT" -ne 0 ]; then
    if rmapi_is_rate_limited "$FOLDER_LISTING"; then
        log "ERROR: reMarkable rate-limited the folder listing (HTTP 429). Not uploading."
        exit 1
    fi
    log "Folder not listable, creating it: $REMARKABLE_FOLDER"
    rmapi mkdir "$REMARKABLE_FOLDER" 2>/dev/null || true
    FOLDER_LISTING=""
fi

# Check if a notebook with this exact name already exists
if echo "$FOLDER_LISTING" | sed 's/^\[f\][[:space:]]*//' | grep -qxF "$JOURNAL_NAME"; then
    log "Note '$JOURNAL_NAME' already exists, skipping upload."
    exit 0
fi

# Upload to reMarkable.
#
# The health check above is read-only and cannot prove writes work: the cloud
# validates root index ordering only on uploads, so a stale rmapi passes every
# read and then fails here. Classify the failure rather than letting a bare
# `set -e` exit report it as nothing in particular.
log "Uploading to reMarkable..."
PUT_EXIT=0
PUT_OUTPUT=$(rmapi put "$RMDOC_FILE" "$REMARKABLE_FOLDER" 2>&1) || PUT_EXIT=$?
if [ "$PUT_EXIT" -ne 0 ]; then
    log "ERROR: upload failed (exit=$PUT_EXIT)"
    rmapi_explain_write_failure "$PUT_OUTPUT" "upload"
    exit 1
fi
[ -n "$PUT_OUTPUT" ] && log "$PUT_OUTPUT"

log "✓ Daily journal created successfully: $JOURNAL_NAME"
