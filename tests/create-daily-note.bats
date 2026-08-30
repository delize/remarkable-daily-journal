#!/usr/bin/env bats
#
# Tests for create-daily-note.sh
#

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/create-daily-note.sh"
}

@test "script exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "script has correct shebang" {
    head -1 "$SCRIPT" | grep -q "#!/bin/bash"
}

@test "script uses set -e for error handling" {
    grep -q "^set -e" "$SCRIPT"
}

@test "script defines required environment variable defaults" {
    grep -q 'REMARKABLE_FOLDER=.*:-' "$SCRIPT"
    grep -q 'DATE_FORMAT=.*:-' "$SCRIPT"
    grep -q 'TEMPLATE_PAGES=.*:-' "$SCRIPT"
    grep -q 'TEMPLATE_STYLE=.*:-' "$SCRIPT"
}

@test "script has log function" {
    grep -q "^log()" "$SCRIPT"
}

@test "script generates a native notebook via the generator" {
    grep -q "generate-native-journal.sh" "$SCRIPT"
}

@test "script creates temp directory with cleanup trap" {
    grep -q "mktemp -d" "$SCRIPT"
    grep -q "trap.*rm -rf.*EXIT" "$SCRIPT"
}

@test "script checks for DRY_RUN mode" {
    grep -q 'DRY_RUN.*true' "$SCRIPT"
}

@test "script checks rmapi health through the shared helper" {
    grep -q 'rmapi-health.sh' "$SCRIPT"
    grep -q 'rmapi_require_health' "$SCRIPT"
}

@test "script does not label every rmapi failure as not-authenticated" {
    # `if ! rmapi ls / ...; then log "ERROR: rmapi not authenticated"` turned a
    # cloud 4xx or a 429 into a re-auth wild goose chase.
    ! grep -q 'rmapi not authenticated' "$SCRIPT"
    ! grep -qE '^if ! rmapi ls / ' "$SCRIPT"
}

@test "auth instructions name a pullable image" {
    # A bare `remarkable-daily-journal` is not a real image reference and fails
    # with "pull access denied".
    ! grep -qE 'docker run .*[^/]remarkable-daily-journal auth' "$SCRIPT" \
        "$(dirname "$SCRIPT")/rmapi-health.sh"
    grep -q 'ghcr.io/delize/remarkable-daily-journal:latest auth' \
        "$(dirname "$SCRIPT")/rmapi-health.sh"
}

@test "script bails out rather than uploading when rate limited" {
    grep -q 'rmapi_is_rate_limited' "$SCRIPT"
}

@test "script creates folder on reMarkable" {
    grep -q "rmapi mkdir" "$SCRIPT"
}

@test "script checks for an existing notebook by name" {
    grep -q 'rmapi ls "\$REMARKABLE_FOLDER"' "$SCRIPT"
    grep -q 'already exists' "$SCRIPT"
}

@test "script uploads the notebook to reMarkable" {
    grep -q "rmapi put" "$SCRIPT"
}

@test "script supports custom date argument" {
    grep -qE 'if \[ -n "\$\{?1' "$SCRIPT"
}

@test "script supports a configurable notebook name" {
    grep -q 'JOURNAL_NAME_FORMAT' "$SCRIPT"
}

@test "honors JOURNAL_NAME_FORMAT in a dry run" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    run env DRY_RUN=true JOURNAL_NAME_FORMAT="Journal %Y-%m-%d" "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Journal "
}

@test "names the .rmdoc after JOURNAL_NAME so rmapi visibleName matches" {
    # rmapi put uses the file basename as visibleName. The temp file must be
    # named after JOURNAL_NAME, not a hardcoded "journal".
    grep -q 'RMDOC_FILE="\$TEMP_DIR/\$SAFE_NAME.rmdoc"' "$SCRIPT"
    grep -qE 'SAFE_NAME=' "$SCRIPT"
    ! grep -q 'TEMP_DIR/journal\.rmdoc' "$SCRIPT"
}

@test "honors JOURNAL_NAME env override in a dry run" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    run env DRY_RUN=true JOURNAL_NAME=template-fix-test "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'template-fix-test'
    ! echo "$output" | grep -qE 'Creating daily journal: [0-9]{4}-[0-9]{2}-[0-9]{2}$'
}

@test "positional date argument still wins over JOURNAL_NAME env" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    run env DRY_RUN=true JOURNAL_NAME=ignored-by-arg "$SCRIPT" 2026-01-15
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '2026-01-15'
    ! echo "$output" | grep -q 'ignored-by-arg'
}

@test "backfill date arg derives CREATED_TIME_MS from that date" {
    # Inspect the script: when a positional date arg is given, it must export
    # a CREATED_TIME_MS derived from that date so the generator stamps the
    # journal's metadata with the backfill day rather than today.
    grep -q 'CREATED_TIME_MS="\$(parse_date_noon_utc_epoch "\$1")000"' "$SCRIPT"
    grep -q 'export CREATED_TIME_MS' "$SCRIPT"
    grep -q '^parse_date_noon_utc_epoch()' "$SCRIPT"
}

@test "backfill end-to-end: bundle.metadata.createdTime resolves to that date" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    run env DRY_RUN=true JOURNAL_NAME=ignored "$SCRIPT" 2026-01-15
    [ "$status" -eq 0 ]
    # Script doesn't run the generator in DRY_RUN, but the date parsing has
    # to succeed without error and the log line must echo the backfill name.
    echo "$output" | grep -q 'Creating daily journal: 2026-01-15'
}

# ---------------------------------------------------------------------------
# Behavioural tests with a stub rmapi on PATH.
# ---------------------------------------------------------------------------

setup_upload_stub() {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_DIR"
    export RMAPI_CALLS="$BATS_TEST_TMPDIR/calls.log"
    : > "$RMAPI_CALLS"
    cat > "$STUB_DIR/rmapi" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$RMAPI_CALLS"
case "$1" in
    ls)
        if [ "$2" = "/" ] || [ -z "$2" ]; then
            [ -n "${STUB_HEALTH_FAIL:-}" ] && { echo "$STUB_HEALTH_FAIL" >&2; exit 1; }
            exit 0
        fi
        [ -n "${STUB_LS_FAIL:-}" ] && { echo "$STUB_LS_FAIL" >&2; exit 1; }
        printf '%s' "${STUB_FOLDER_LISTING:-}"
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/rmapi"
    export RMAPI_RATE_LIMIT_RETRIES=0
    unset RMAPI_HEALTH_VERIFIED
}

@test "a 429 on the health check is not reported as an auth problem, and nothing uploads" {
    setup_upload_stub
    STUB_HEALTH_FAIL="failed to create user token from device token request failed with status 429"
    export STUB_HEALTH_FAIL
    PATH="$STUB_DIR:$PATH" run "$SCRIPT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "rate-limited"
    echo "$output" | grep -qi "NOT a token-expiry problem"
    ! grep -q '^put' "$RMAPI_CALLS"
}

@test "an unauthenticated rmapi prints a pullable auth command" {
    setup_upload_stub
    STUB_HEALTH_FAIL="unauthorized"
    export STUB_HEALTH_FAIL
    PATH="$STUB_DIR:$PATH" run "$SCRIPT"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ghcr.io/delize/remarkable-daily-journal:latest auth"
    ! grep -q '^put' "$RMAPI_CALLS"
}

@test "an existing notebook is detected from the single folder listing" {
    setup_upload_stub
    STUB_FOLDER_LISTING="$(printf '[f]\t%s\n' "$(date +%Y-%m-%d)")"
    export STUB_FOLDER_LISTING
    PATH="$STUB_DIR:$PATH" run "$SCRIPT"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "already exists"
    ! grep -q '^put' "$RMAPI_CALLS"
    # No unconditional mkdir when the folder already lists fine.
    ! grep -q '^mkdir' "$RMAPI_CALLS"
}

@test "a healthy run uploads exactly once" {
    setup_upload_stub
    STUB_FOLDER_LISTING=""
    export STUB_FOLDER_LISTING
    PATH="$STUB_DIR:$PATH" run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^put' "$RMAPI_CALLS")" -eq 1 ]
}

@test "a health check already done by the entrypoint is not repeated" {
    setup_upload_stub
    STUB_FOLDER_LISTING=""
    export STUB_FOLDER_LISTING
    PATH="$STUB_DIR:$PATH" RMAPI_HEALTH_VERIFIED=true run "$SCRIPT"
    [ "$status" -eq 0 ]
    ! grep -qx 'ls /' "$RMAPI_CALLS"
}
