#!/bin/bash
#
# rmapi-health.sh
# Shared rmapi health classification and rate-limit helpers.
#
# Sourced (not executed) by entrypoint.sh, create-daily-note.sh and
# cleanup-old-journals.sh so every script classifies an rmapi failure the same
# way. Before this existed each script rolled its own `rmapi ls /` check and
# reported any failure as "not authenticated", which sent people chasing a
# token problem when the cloud was really returning a 4xx.
#
# Why rate limiting matters here: every rmapi invocation is a fresh process
# that re-exchanges the stored device token for a user token. A script that
# shells out to rmapi once per document turns N documents into N token
# exchanges in a few seconds, and reMarkable's auth endpoint starts refusing
# them:
#
#   auth.go:53: failed to create user token from device token
#   request failed with status 429
#
# So callers should (a) batch rmapi calls, (b) treat 429 as its own condition
# rather than folding it into "auth failed", and (c) stop rather than grind
# through the rest of a loop once they see one.
#
# Environment variables:
#   RMAPI_RATE_LIMIT_RETRIES  - Health-check retries on a 429 (default: 2)
#   RMAPI_RATE_LIMIT_BACKOFF_SECONDS
#                             - First backoff, doubled per retry (default: 60)
#   RMAPI_HEALTH_VERIFIED     - Set to "true" by a caller that already ran a
#                               successful health check in this cycle, so child
#                               scripts skip a redundant token exchange.
#

# Health classification, used as return codes by rmapi_check_health.
RMAPI_OK=0
RMAPI_UNAUTHENTICATED=1
RMAPI_KILLED=2
RMAPI_CLOUD_ERROR=3
RMAPI_RATE_LIMITED=4

RMAPI_RATE_LIMIT_RETRIES="${RMAPI_RATE_LIMIT_RETRIES:-2}"
RMAPI_RATE_LIMIT_BACKOFF_SECONDS="${RMAPI_RATE_LIMIT_BACKOFF_SECONDS:-60}"

# Use the sourcing script's logger when it has one, otherwise a plain default.
if ! declare -F log >/dev/null 2>&1; then
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
fi

# True when rmapi output carries reMarkable's rate-limit rejection.
rmapi_is_rate_limited() {
    printf '%s' "${1:-}" | grep -qiE 'status 429|429 too many requests|rate limit'
}

# True when rmapi output is a cloud-side API/sync failure rather than a token
# problem (e.g. HTTP 400 on the sync mirror endpoint after an API change).
rmapi_is_cloud_error() {
    printf '%s' "${1:-}" | grep -qiE 'failed to mirror|failed to build documents tree|request failed with status [45][0-9][0-9]'
}

# Log the standard explanation for a given health code. Kept separate from the
# classification so callers can decide whether to be noisy.
rmapi_explain_health() {
    case "${1:-1}" in
        "$RMAPI_KILLED")
            log "ERROR: rmapi was killed (exit code 137/139)"
            log "This usually means the container has insufficient memory."
            log "Increase the memory limit to at least 768MB:"
            log ""
            log "  Docker Compose: mem_limit: 768m"
            log "  Docker run: --memory=768m"
            log ""
            ;;
        "$RMAPI_RATE_LIMITED")
            log "ERROR: reMarkable rate-limited us (HTTP 429). This is NOT a token-expiry problem."
            log "Every rmapi call re-exchanges the device token for a user token, so a burst"
            log "of calls trips the auth endpoint's limiter. The limit clears on its own;"
            log "the next scheduled run should succeed."
            log "Output: ${LAST_RMAPI_OUTPUT:-<none>}"
            ;;
        "$RMAPI_CLOUD_ERROR")
            log "ERROR: reMarkable cloud API error (this is NOT a token-expiry problem)"
            log "Output: ${LAST_RMAPI_OUTPUT:-<none>}"
            ;;
        *)
            log "ERROR: rmapi is not authenticated. Re-run the container's auth command:"
            log ""
            log "  docker run -it --rm -v rmapi-config:/app/.config/rmapi \\"
            log "    ghcr.io/delize/remarkable-daily-journal:latest auth"
            log ""
            log "Output: ${LAST_RMAPI_OUTPUT:-<none>}"
            ;;
    esac
}

# Classify the rmapi <-> reMarkable cloud connection with a single `rmapi ls /`.
# Sets LAST_RMAPI_OUTPUT for issue reporting. Returns one of the RMAPI_* codes.
# A 429 is retried with doubling backoff first, since the limiter self-clears.
rmapi_check_health() {
    local output exit_code attempt=0
    local backoff="$RMAPI_RATE_LIMIT_BACKOFF_SECONDS"

    while :; do
        output=$(rmapi ls / 2>&1) && exit_code=0 || exit_code=$?
        LAST_RMAPI_OUTPUT="$output"

        if [ "$exit_code" -eq 0 ]; then
            return "$RMAPI_OK"
        fi

        # 137 = SIGKILL (OOM), 139 = SIGSEGV
        if [ "$exit_code" -eq 137 ] || [ "$exit_code" -eq 139 ]; then
            return "$RMAPI_KILLED"
        fi

        # Check 429 before the generic 4xx/5xx match below, which would
        # otherwise swallow it and mislabel it as a plain cloud error.
        if rmapi_is_rate_limited "$output"; then
            if [ "$attempt" -ge "$RMAPI_RATE_LIMIT_RETRIES" ]; then
                return "$RMAPI_RATE_LIMITED"
            fi
            attempt=$((attempt + 1))
            log "reMarkable returned HTTP 429 (rate limited). Backing off ${backoff}s (retry ${attempt}/${RMAPI_RATE_LIMIT_RETRIES})..."
            sleep "$backoff"
            backoff=$((backoff * 2))
            continue
        fi

        if rmapi_is_cloud_error "$output"; then
            return "$RMAPI_CLOUD_ERROR"
        fi

        return "$RMAPI_UNAUTHENTICATED"
    done
}

# Health check that a parent process can satisfy on our behalf.
#
# entrypoint.sh already verifies health once per cycle before invoking the
# journal scripts. Without this, each script repeated the check and burned
# another token exchange against the same limiter we are trying to stay under.
# Standalone invocations (RMAPI_HEALTH_VERIFIED unset) still check for
# themselves. Returns an RMAPI_* code.
rmapi_require_health() {
    if [ "${RMAPI_HEALTH_VERIFIED:-}" = "true" ]; then
        return "$RMAPI_OK"
    fi

    local rc=0
    rmapi_check_health || rc=$?
    if [ "$rc" -eq "$RMAPI_OK" ]; then
        export RMAPI_HEALTH_VERIFIED=true
    fi
    return "$rc"
}
