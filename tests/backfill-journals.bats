#!/usr/bin/env bats
#
# Tests for scripts/backfill-journals.sh
#

setup() {
    PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$PROJECT_DIR/scripts/backfill-journals.sh"
}

@test "script exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "script refuses to run without a date range" {
    run "$SCRIPT"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "Usage:"
}

@test "script rejects a reversed range" {
    run "$SCRIPT" 2026-08-29 2026-08-19
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "after end date"
}

@test "dry run enumerates the inclusive range without touching rmapi" {
    run env BACKFILL_DRY_RUN=true "$SCRIPT" 2026-08-19 2026-08-29
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Backfilling 11 day(s)"
    echo "$output" | grep -q "would create: 2026-08-19"
    echo "$output" | grep -q "would create: 2026-08-29"
    ! echo "$output" | grep -q "would create: 2026-08-30"
}

@test "a single-day range is one day, not zero" {
    run env BACKFILL_DRY_RUN=true "$SCRIPT" 2026-08-19 2026-08-19
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Backfilling 1 day(s)"
}

@test "the range crosses a month boundary correctly" {
    run env BACKFILL_DRY_RUN=true "$SCRIPT" 2026-08-30 2026-09-02
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Backfilling 4 day(s)"
    echo "$output" | grep -q "would create: 2026-09-01"
}

setup_stub() {
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
        if [ "$2" = "/" ] || [ -z "$2" ]; then exit 0; fi
        exit 0
        ;;
    put)
        if [ -n "${STUB_PUT_FAIL:-}" ]; then
            echo "$STUB_PUT_FAIL" >&2
            exit 1
        fi
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/rmapi"
    export BACKFILL_DELAY_SECONDS=0
    export RMAPI_RATE_LIMIT_RETRIES=0
    unset RMAPI_HEALTH_VERIFIED
}

@test "each day is created once, and the health check is not repeated per day" {
    # 11 days of `create-daily-note.sh` would each re-exchange the device token
    # for their own health check. Over a tight loop that is the exact burst that
    # gets the account 429'd, so the range shares one check.
    setup_stub
    PATH="$STUB_DIR:$PATH" run "$SCRIPT" 2026-08-19 2026-08-23
    [ "$status" -eq 0 ]
    [ "$(grep -c '^put' "$RMAPI_CALLS")" -eq 5 ]
    [ "$(grep -cx 'ls /' "$RMAPI_CALLS")" -eq 1 ]
    echo "$output" | grep -q "created-or-existing=5"
}

@test "a 429 aborts the range instead of hammering the rest of it" {
    setup_stub
    STUB_PUT_FAIL="ERROR: request failed with status 429"; export STUB_PUT_FAIL
    PATH="$STUB_DIR:$PATH" run "$SCRIPT" 2026-08-19 2026-08-29
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "ABORTING"
    # Stopped on the first refused upload, not after all eleven.
    [ "$(grep -c '^put' "$RMAPI_CALLS")" -eq 1 ]
}

@test "a non-rate-limit failure continues with the remaining days" {
    setup_stub
    STUB_PUT_FAIL="ERROR: something else went wrong"; export STUB_PUT_FAIL
    PATH="$STUB_DIR:$PATH" run "$SCRIPT" 2026-08-19 2026-08-21
    [ "$status" -eq 1 ]
    ! echo "$output" | grep -q "ABORTING"
    [ "$(grep -c '^put' "$RMAPI_CALLS")" -eq 3 ]
    echo "$output" | grep -q "failed=3"
}

@test "the backfilled notebook is named for its own date, not today" {
    setup_stub
    PATH="$STUB_DIR:$PATH" run "$SCRIPT" 2026-08-19 2026-08-19
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Creating daily journal: 2026-08-19"
    ! echo "$output" | grep -q "Creating daily journal: $(date +%Y-%m-%d)"
}
