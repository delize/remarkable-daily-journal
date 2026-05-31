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

@test "script checks for existing notebook" {
    grep -q "rmapi find" "$SCRIPT"
}

@test "script uploads the notebook to reMarkable" {
    grep -q "rmapi put" "$SCRIPT"
}

@test "script supports custom date argument" {
    grep -q 'if \[ -n "\$1" \]' "$SCRIPT"
}
