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

@test "script checks rmapi authentication" {
    grep -q "rmapi ls" "$SCRIPT"
}

@test "script lists folder contents for scanning" {
    grep -q "rmapi ls.*REMARKABLE_FOLDER" "$SCRIPT"
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

@test "script calculates cutoff date from CLEANUP_KEEP_DAYS" {
    grep -q 'CUTOFF_DATE' "$SCRIPT"
    grep -q 'CLEANUP_KEEP_DAYS' "$SCRIPT"
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
