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

@test "script checks rmapi authentication" {
    grep -q "rmapi ls" "$SCRIPT"
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
    date -d "2026-01-15" +%Y-%m-%d >/dev/null 2>&1 || skip "GNU date -d not available"
    run env DRY_RUN=true JOURNAL_NAME=ignored-by-arg "$SCRIPT" 2026-01-15
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '2026-01-15'
    ! echo "$output" | grep -q 'ignored-by-arg'
}

@test "backfill date arg derives CREATED_TIME_MS from that date" {
    # Inspect the script: when a positional date arg is given, it must export
    # CREATED_TIME_MS derived from that date so the generator stamps the
    # journal's metadata with the backfill day rather than today.
    grep -q 'CREATED_TIME_MS=.*date -d "\$1 12:00:00 UTC" +%s' "$SCRIPT"
    grep -q 'export CREATED_TIME_MS' "$SCRIPT"
}
