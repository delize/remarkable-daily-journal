#!/bin/bash
#
# github-notify.sh
# Idempotent health reporting from the running container to GitHub Issues.
#
# When the daily journal hits a reMarkable cloud/API or auth failure, the
# container opens ONE issue per failure kind (keyed by label, so repeated
# failures comment on the same issue instead of spawning duplicates) and
# closes it automatically when the next run succeeds.
#
# Usage:
#   github-notify.sh failing <api|auth|error> <body>
#   github-notify.sh ok
#
# Opt-in: a silent no-op unless BOTH GITHUB_TOKEN and GITHUB_REPO are set.
#   GITHUB_TOKEN  PAT (classic: repo scope; fine-grained: Issues read+write)
#   GITHUB_REPO   owner/repo (e.g. delize/remarkable-daily-journal)
#   GITHUB_API    optional, defaults to https://api.github.com
#
# Requires: curl, jq.

set -uo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [health-notify] $*"; }

GITHUB_API="${GITHUB_API:-https://api.github.com}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
REPO="${GITHUB_REPO:-}"

API_LABEL="cloud-api-failure"
AUTH_LABEL="cloud-auth-failure"
ERR_LABEL="journal-error"
FAILURE_LABELS="$API_LABEL $AUTH_LABEL $ERR_LABEL"

if [ -z "$TOKEN" ] || [ -z "$REPO" ]; then
    # Reporting not configured; do nothing so existing setups are unaffected.
    exit 0
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "curl and jq are required for issue reporting; skipping."
    exit 0
fi

# api <METHOD> <path> [json-body] -> response body on stdout (empty on failure)
api() {
    local method="$1" path="$2" body="${3:-}"
    local -a args=(-sS -X "$method"
        -H "Authorization: Bearer $TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    [ -n "$body" ] && args+=(-d "$body")
    curl "${args[@]}" "$GITHUB_API/repos/$REPO$path" 2>/dev/null
}

label_for() { case "$1" in api) echo "$API_LABEL";; auth) echo "$AUTH_LABEL";; *) echo "$ERR_LABEL";; esac; }
title_for() {
    case "$1" in
        api)  echo "🔴 reMarkable cloud API failure (rmapi) — daily journal failing";;
        auth) echo "🔴 reMarkable auth/token failure (rmapi) — re-auth needed";;
        *)    echo "🔴 Daily journal error";;
    esac
}

open_or_update() {
    local kind="$1" body="$2"
    local label title existing num state body_json
    label="$(label_for "$kind")"
    title="$(title_for "$kind")"

    # Newest issue (open or closed) carrying this label.
    existing="$(api GET "/issues?state=all&labels=$label&per_page=1" \
        | jq -r '.[0] | if . == null then "" else "\(.number) \(.state)" end')"
    num="$(echo "$existing" | awk '{print $1}')"
    state="$(echo "$existing" | awk '{print $2}')"
    body_json="$(jq -Rs . <<<"$body")"

    if [ -z "$num" ]; then
        if api POST "/issues" \
            "$(jq -nc --arg t "$title" --argjson b "$body_json" --arg l "$label" \
                '{title:$t, body:$b, labels:[$l]}')" \
            | jq -e '.number' >/dev/null 2>&1; then
            log "Opened issue ($label)."
        else
            log "Failed to open issue ($label)."
        fi
    else
        [ "$state" = "closed" ] && api PATCH "/issues/$num" '{"state":"open"}' >/dev/null && log "Reopened #$num."
        api POST "/issues/$num/comments" "$(jq -nc --argjson b "$body_json" '{body:$b}')" >/dev/null \
            && log "Updated #$num." || log "Failed to comment on #$num."
    fi
}

close_recovered() {
    local label num msg
    msg="✅ Recovered at $(date -u '+%Y-%m-%d %H:%M UTC') — daily journal ran successfully. Closing automatically."
    for label in $FAILURE_LABELS; do
        for num in $(api GET "/issues?state=open&labels=$label&per_page=20" | jq -r '.[].number' 2>/dev/null); do
            api POST "/issues/$num/comments" "$(jq -nc --arg b "$msg" '{body:$b}')" >/dev/null
            api PATCH "/issues/$num" '{"state":"closed"}' >/dev/null && log "Closed #$num (recovered)."
        done
    done
}

case "${1:-}" in
    failing) open_or_update "${2:-error}" "${3:-No details provided.}";;
    ok)      close_recovered;;
    *)       echo "Usage: github-notify.sh failing <api|auth|error> <body> | ok" >&2; exit 2;;
esac
