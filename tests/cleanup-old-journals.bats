#!/usr/bin/env bats
#
# Tests for cleanup-old-journals.sh
#

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/cleanup-old-journals.sh"
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

@test "script defines CLEANUP_ENABLED variable" {
    grep -q 'CLEANUP_ENABLED=.*:-' "$SCRIPT"
}

@test "script defines SIZE_THRESHOLD variable" {
    grep -q 'SIZE_THRESHOLD=.*:-' "$SCRIPT"
}

@test "script defines CLEANUP_KEEP_DAYS variable" {
    grep -q 'CLEANUP_KEEP_DAYS=.*:-' "$SCRIPT"
}

@test "script has log function with cleanup tag" {
    grep -q '\[cleanup\]' "$SCRIPT"
}

@test "script checks CLEANUP_ENABLED before running" {
    grep -q 'CLEANUP_ENABLED.*!=.*true' "$SCRIPT"
}

@test "script creates temp directory with cleanup trap" {
    grep -q "mktemp -d" "$SCRIPT"
    grep -q "trap.*rm -rf.*EXIT" "$SCRIPT"
}

@test "script uses size threshold for fallback comparison" {
    grep -q "SIZE_THRESHOLD" "$SCRIPT"
    grep -q "gt.*SIZE_THRESHOLD" "$SCRIPT"
}

@test "script checks rmapi health through the shared helper" {
    grep -q 'rmapi-health.sh' "$SCRIPT"
    grep -q 'rmapi_require_health' "$SCRIPT"
}

@test "script lists folder contents for scanning" {
    grep -q 'rmapi -json ls "\$REMARKABLE_FOLDER"' "$SCRIPT"
}

@test "script downloads journals for inspection" {
    grep -q "rmapi get" "$SCRIPT"
}

@test "script removes unused journals" {
    grep -q "rmapi rm" "$SCRIPT"
}

@test "script checks for .rm annotation files in ZIP" {
    grep -q '\.rm' "$SCRIPT"
    grep -q 'unzip' "$SCRIPT"
}

@test "script checks ZIP magic bytes for format detection" {
    grep -q 'head -c2' "$SCRIPT"
    grep -q '"PK"' "$SCRIPT"
}

@test "script skips today's journal" {
    grep -q 'TODAY_DATE' "$SCRIPT"
    grep -q 'Skip today' "$SCRIPT"
}

@test "script applies a recency gate from CLEANUP_KEEP_HOURS" {
    grep -q 'CLEANUP_KEEP_HOURS' "$SCRIPT"
    grep -q 'ModifiedClient' "$SCRIPT"
}

@test "recency gate only inspects journals YOUNGER than CLEANUP_KEEP_HOURS" {
    # Flipped policy: settled journals (>= window) are skipped without download.
    grep -q 'AGE_HOURS.*-ge.*CLEANUP_KEEP_HOURS' "$SCRIPT"
    grep -q 'settled' "$SCRIPT"
    # The old "less than" gate is gone.
    ! grep -q 'AGE_HOURS.*-lt.*CLEANUP_KEEP_HOURS' "$SCRIPT"
}

@test "script never runs a per-document rmapi stat" {
    # One `rmapi stat` per document meant one token exchange per document,
    # which rate-limited the whole account. Metadata comes from the single
    # folder listing instead.
    ! grep -qE '^[^#]*rmapi stat' "$SCRIPT"
}

@test "script persists a verified-non-empty cache" {
    grep -q 'CLEANUP_CACHE' "$SCRIPT"
    grep -q 'cache_lookup_mc' "$SCRIPT"
    grep -q 'cache_record' "$SCRIPT"
    grep -q 'cache_forget' "$SCRIPT"
}

@test "script deletes only empty journals by .rm size" {
    grep -q 'EMPTY_RM_MAX_BYTES' "$SCRIPT"
}

@test "script supports a dry-run mode" {
    grep -q 'CLEANUP_DRY_RUN' "$SCRIPT"
}

@test "script reports cleanup stats" {
    grep -q 'checked=.*deleted=.*kept=' "$SCRIPT"
}

@test "script has check_has_annotations function" {
    grep -q 'check_has_annotations' "$SCRIPT"
}

@test "script uses stat for file size in fallback" {
    grep -q "stat" "$SCRIPT"
}

@test "script captures the real rmapi get exit code" {
    # The old `... ) || true` then `GET_EXIT=$?` captured the exit of `true`,
    # so a 429'd download looked like a successful one that found nothing.
    grep -q 'GET_OUTPUT=.*|| GET_EXIT=\$?' "$SCRIPT"
    ! grep -qE 'rmapi get .*\) \|\| true' "$SCRIPT"
}

# ---------------------------------------------------------------------------
# Behavioural tests, driven by an rmapi stub on PATH.
# ---------------------------------------------------------------------------

# Build a stub rmapi that records every invocation and is steered by env vars:
#   STUB_HEALTH_FAIL   text printed (and non-zero exit) for `rmapi ls /`
#   STUB_LS_FAIL       text printed (and non-zero exit) for a folder listing
#   STUB_LISTING_JSON  path to the JSON array `rmapi -json ls <folder>` returns
#   STUB_GET_FAIL      text printed (and non-zero exit) for `rmapi get`
#   STUB_GET_EXIT      exit code to use with STUB_GET_FAIL (default 1)
#   STUB_GET_FILE      file copied into cwd by a successful `rmapi get`
#   RMAPI_CALLS        file every argv line is appended to
#   RMAPI_REMOVED      file every removed path is appended to
setup_stub() {
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUB_DIR"
    export RMAPI_CALLS="$BATS_TEST_TMPDIR/calls.log"
    export RMAPI_REMOVED="$BATS_TEST_TMPDIR/removed.log"
    : > "$RMAPI_CALLS"
    : > "$RMAPI_REMOVED"

    cat > "$STUB_DIR/rmapi" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$RMAPI_CALLS"

args=("$@")
json=false
if [ "${args[0]:-}" = "-json" ]; then
    json=true
    args=("${args[@]:1}")
fi
cmd="${args[0]:-}"
target="${args[1]:-}"

case "$cmd" in
    ls)
        if [ -z "$target" ] || [ "$target" = "/" ]; then
            if [ -n "${STUB_HEALTH_FAIL:-}" ]; then
                echo "$STUB_HEALTH_FAIL" >&2
                exit 1
            fi
            printf '[d]\tDaily Journal\n'
            exit 0
        fi
        if [ -n "${STUB_LS_FAIL:-}" ]; then
            echo "$STUB_LS_FAIL" >&2
            exit 1
        fi
        if [ "$json" = true ]; then
            cat "$STUB_LISTING_JSON"
        else
            jq -r '.[] | "[f]\t" + .name' "$STUB_LISTING_JSON"
        fi
        exit 0
        ;;
    stat)
        echo "stub: rmapi stat must not be called (one token exchange per doc)" >&2
        exit 90
        ;;
    get)
        if [ -n "${STUB_GET_FAIL:-}" ]; then
            echo "$STUB_GET_FAIL" >&2
            exit "${STUB_GET_EXIT:-1}"
        fi
        cp "$STUB_GET_FILE" "./$(basename "$target").rmdoc"
        exit 0
        ;;
    rm)
        printf '%s\n' "$target" >> "$RMAPI_REMOVED"
        exit 0
        ;;
esac
exit 0
STUB
    chmod +x "$STUB_DIR/rmapi"

    export CLEANUP_CACHE="$BATS_TEST_TMPDIR/cache.tsv"
    export CLEANUP_API_DELAY_SECONDS=0
    export RMAPI_RATE_LIMIT_RETRIES=0
    export REMARKABLE_FOLDER="/Daily Journal"
    unset RMAPI_HEALTH_VERIFIED
}

# An .rmdoc whose single page .rm is below EMPTY_RM_MAX_BYTES (never written on).
make_empty_bundle() {
    local dir="$BATS_TEST_TMPDIR/empty" out="$BATS_TEST_TMPDIR/empty.rmdoc"
    mkdir -p "$dir"
    head -c 409 /dev/zero | tr '\0' 'a' > "$dir/page.rm"
    (cd "$dir" && zip -q -X -0 "$out" page.rm)
    echo "$out"
}

# An .rmdoc whose page .rm is well above the threshold (has strokes).
make_written_bundle() {
    local dir="$BATS_TEST_TMPDIR/written" out="$BATS_TEST_TMPDIR/written.rmdoc"
    mkdir -p "$dir"
    head -c 40000 /dev/urandom > "$dir/page.rm"
    (cd "$dir" && zip -q -X -0 "$out" page.rm)
    echo "$out"
}

# JSON listing of documents: write_listing <name> <modifiedClient> [<name> <mc>...]
write_listing() {
    local out="$BATS_TEST_TMPDIR/listing.json"
    {
        echo '['
        local first=1
        while [ "$#" -gt 0 ]; do
            [ "$first" -eq 1 ] || echo ','
            first=0
            printf '  {"id":"x","name":%s,"type":"DocumentType","modifiedClient":%s}' \
                "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "$2" '$v')"
            shift 2
        done
        echo
        echo ']'
    } > "$out"
    export STUB_LISTING_JSON="$out"
}

iso_hours_ago() {
    if date -u -d "@0" >/dev/null 2>&1; then
        date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ
    fi
}

run_cleanup() {
    PATH="$STUB_DIR:$PATH" run "$SCRIPT"
}

@test "reads metadata from ONE folder listing, never a stat per document" {
    setup_stub
    write_listing \
        "2020-01-01" "$(iso_hours_ago 200)" \
        "2020-01-02" "$(iso_hours_ago 300)" \
        "2020-01-03" "$(iso_hours_ago 400)"
    run_cleanup
    [ "$status" -eq 0 ]
    ! grep -q '^stat' "$RMAPI_CALLS"
    [ "$(grep -c 'json ls' "$RMAPI_CALLS")" -eq 1 ]
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "settled journals are skipped without any download" {
    setup_stub
    write_listing "2020-01-01" "$(iso_hours_ago 500)"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Skipping (settled"
    ! grep -q '^get' "$RMAPI_CALLS"
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "a document with no ModifiedClient fails CLOSED and is never inspected" {
    # The old gate was `if [ -n "$MC" ]`, so a failed metadata read skipped the
    # recency check entirely and sent a settled journal to a full download,
    # where an under-threshold result would have deleted it.
    setup_stub
    write_listing "2020-01-15" ""
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no ModifiedClient"
    ! grep -q '^get' "$RMAPI_CALLS"
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "an unparseable ModifiedClient fails CLOSED" {
    setup_stub
    write_listing "2020-01-15" "not-a-timestamp"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "unparseable ModifiedClient"
    ! grep -q '^get' "$RMAPI_CALLS"
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "an in-window empty journal is deleted" {
    setup_stub
    STUB_GET_FILE="$(make_empty_bundle)"; export STUB_GET_FILE
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    grep -q "Daily Journal/2020-01-15" "$RMAPI_REMOVED"
}

@test "an in-window written-on journal is kept and cached" {
    setup_stub
    STUB_GET_FILE="$(make_written_bundle)"; export STUB_GET_FILE
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    [ ! -s "$RMAPI_REMOVED" ]
    grep -q "2020-01-15" "$CLEANUP_CACHE"
}

@test "a failed download never becomes a deletion" {
    # A 429'd or otherwise failed `rmapi get` produced no .rm layers, which the
    # old code read as "empty" and deleted.
    setup_stub
    STUB_GET_FAIL="ERROR: something went wrong"; export STUB_GET_FAIL
    STUB_GET_EXIT=1; export STUB_GET_EXIT
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Download FAILED"
    echo "$output" | grep -q "Cannot verify contents, keeping"
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "a 429 on the folder listing aborts the pass" {
    setup_stub
    STUB_LS_FAIL="failed to create user token from device token request failed with status 429"
    export STUB_LS_FAIL
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ABORTING pass"
    ! grep -q '^get' "$RMAPI_CALLS"
}

@test "a 429 mid-loop aborts instead of grinding through the rest" {
    setup_stub
    STUB_GET_FAIL="ERROR: request failed with status 429"; export STUB_GET_FAIL
    write_listing \
        "2020-01-15" "$(iso_hours_ago 2)" \
        "2020-01-16" "$(iso_hours_ago 2)" \
        "2020-01-17" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "ABORTING pass"
    # Stopped after the first refused download, not after all three.
    [ "$(grep -c '^get' "$RMAPI_CALLS")" -eq 1 ]
    [ ! -s "$RMAPI_REMOVED" ]
}

@test "a 429 on the health check skips the pass without touching anything" {
    setup_stub
    STUB_HEALTH_FAIL="failed to create user token from device token request failed with status 429"
    export STUB_HEALTH_FAIL
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "rate-limited"
    ! grep -q 'json ls' "$RMAPI_CALLS"
}

@test "CLEANUP_MAX_DOCS caps downloads in a single pass" {
    setup_stub
    STUB_GET_FILE="$(make_written_bundle)"; export STUB_GET_FILE
    write_listing \
        "2020-01-15" "$(iso_hours_ago 2)" \
        "2020-01-16" "$(iso_hours_ago 2)" \
        "2020-01-17" "$(iso_hours_ago 2)" \
        "2020-01-18" "$(iso_hours_ago 2)"
    CLEANUP_MAX_DOCS=2 run_cleanup
    [ "$status" -eq 0 ]
    [ "$(grep -c '^get' "$RMAPI_CALLS")" -eq 2 ]
    echo "$output" | grep -q "Reached CLEANUP_MAX_DOCS"
}

@test "an already-verified health check is not repeated" {
    setup_stub
    write_listing "2020-01-01" "$(iso_hours_ago 500)"
    RMAPI_HEALTH_VERIFIED=true run_cleanup
    [ "$status" -eq 0 ]
    ! grep -qx 'ls /' "$RMAPI_CALLS"
}

@test "dry run never calls rmapi rm" {
    setup_stub
    STUB_GET_FILE="$(make_empty_bundle)"; export STUB_GET_FILE
    write_listing "2020-01-15" "$(iso_hours_ago 2)"
    CLEANUP_DRY_RUN=true run_cleanup
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "DRY RUN: would remove"
    [ ! -s "$RMAPI_REMOVED" ]
}
