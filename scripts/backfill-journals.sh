#!/bin/bash
#
# backfill-journals.sh
# Creates dated journals for a range of past days, one per day.
#
# Runs INSIDE the container (it needs rmapi and create-daily-note.sh), so it is
# bash like the rest of the container scripts rather than a cross-platform
# helper:
#
#   docker exec remarkable-daily-journal \
#       /app/scripts/backfill-journals.sh 2026-08-19 2026-08-29
#
# Why this exists instead of a shell for-loop: each create-daily-note.sh run
# spends two rmapi calls (a folder listing and an upload), and every rmapi call
# is a fresh process that re-exchanges the device token. A tight loop over 11
# days is 22 token exchanges in a few seconds, which is precisely the burst that
# gets the account 429'd. So this does one health check for the whole range,
# spaces the days out, and stops on the first 429 rather than making it worse.
#
# create-daily-note.sh already skips a date whose notebook exists, so re-running
# over a partially-completed range is safe.
#
# Environment variables:
#   BACKFILL_DELAY_SECONDS - Seconds between days (default: 20)
#   BACKFILL_DRY_RUN       - "true" to list the dates without creating anything
#   plus everything create-daily-note.sh honours (TEMPLATE_STYLE, etc.)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKFILL_DELAY_SECONDS="${BACKFILL_DELAY_SECONDS:-20}"
BACKFILL_DRY_RUN="${BACKFILL_DRY_RUN:-false}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [backfill] $*"
}

# shellcheck source=../rmapi-health.sh
. "$APP_DIR/rmapi-health.sh"

START_DATE="${1:-}"
END_DATE="${2:-}"

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    echo "Usage: backfill-journals.sh <start YYYY-MM-DD> <end YYYY-MM-DD>" >&2
    echo "" >&2
    echo "Creates one journal per day across the inclusive range." >&2
    echo "Dates that already have a notebook are skipped." >&2
    exit 2
fi

# Portable day arithmetic: GNU date (Alpine) and BSD date (macOS, where the
# tests run). Echoes the day N days after START_DATE.
day_offset() {
    local base="$1" n="$2"
    if date -d "$base" +%s >/dev/null 2>&1; then
        date -u -d "$base UTC +$n days" +%Y-%m-%d
    else
        date -u -j -v+"$n"d -f "%Y-%m-%d" "$base" +%Y-%m-%d
    fi
}

to_epoch() {
    if date -d "$1" +%s >/dev/null 2>&1; then
        date -u -d "$1 12:00:00 UTC" +%s
    else
        date -u -j -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" +%s
    fi
}

START_EPOCH=$(to_epoch "$START_DATE")
END_EPOCH=$(to_epoch "$END_DATE")

if [ "$START_EPOCH" -gt "$END_EPOCH" ]; then
    log "ERROR: start date $START_DATE is after end date $END_DATE"
    exit 2
fi

DAYS=$(( (END_EPOCH - START_EPOCH) / 86400 + 1 ))
log "Backfilling $DAYS day(s): $START_DATE through $END_DATE"

if [ "$BACKFILL_DRY_RUN" = "true" ]; then
    i=0
    while [ "$i" -lt "$DAYS" ]; do
        log "  would create: $(day_offset "$START_DATE" "$i")"
        i=$((i + 1))
    done
    log "DRY RUN: nothing created"
    exit 0
fi

# One health check for the whole range. create-daily-note.sh honours
# RMAPI_HEALTH_VERIFIED, so the per-day runs do not each re-exchange the token.
HEALTH_RC=0
rmapi_require_health || HEALTH_RC=$?
if [ "$HEALTH_RC" -ne 0 ]; then
    rmapi_explain_health "$HEALTH_RC"
    log "ERROR: cannot reach the reMarkable cloud, backfilling nothing"
    exit 1
fi
export RMAPI_HEALTH_VERIFIED=true

CREATED=0
FAILED=0
i=0
while [ "$i" -lt "$DAYS" ]; do
    DAY=$(day_offset "$START_DATE" "$i")
    i=$((i + 1))

    [ "$i" -eq 1 ] || sleep "$BACKFILL_DELAY_SECONDS"

    log "Creating $DAY ($i/$DAYS)"
    DAY_EXIT=0
    DAY_OUTPUT=$("$APP_DIR/create-daily-note.sh" "$DAY" 2>&1) || DAY_EXIT=$?
    echo "$DAY_OUTPUT"

    if [ "$DAY_EXIT" -eq 0 ]; then
        CREATED=$((CREATED + 1))
        continue
    fi

    FAILED=$((FAILED + 1))
    if rmapi_is_rate_limited "$DAY_OUTPUT"; then
        log "ABORTING: reMarkable returned HTTP 429. Raise BACKFILL_DELAY_SECONDS"
        log "  and re-run the same range — completed days are skipped."
        log "Backfill aborted after $CREATED day(s): $START_DATE through $DAY"
        exit 1
    fi
    log "  $DAY failed (exit=$DAY_EXIT), continuing with the rest"
done

log "Backfill complete: created-or-existing=$CREATED failed=$FAILED"
[ "$FAILED" -eq 0 ]
