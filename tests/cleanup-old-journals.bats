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

@test "script has log function with cleanup tag" {
    grep -q '\[cleanup\]' "$SCRIPT"
}

@test "script checks CLEANUP_ENABLED before running" {
    grep -q 'CLEANUP_ENABLED.*!=.*true' "$SCRIPT"
}

@test "script calculates yesterday's date" {
    grep -q 'yesterday' "$SCRIPT"
}

@test "script creates temp directory with cleanup trap" {
    grep -q "mktemp -d" "$SCRIPT"
    grep -q "trap.*rm -rf.*EXIT" "$SCRIPT"
}

@test "script uses size threshold for comparison" {
    grep -q "SIZE_THRESHOLD" "$SCRIPT"
    grep -q "gt.*SIZE_THRESHOLD" "$SCRIPT"
}

@test "script checks rmapi authentication" {
    grep -q "rmapi ls" "$SCRIPT"
}

@test "script searches for yesterday's journal" {
    grep -q "rmapi find" "$SCRIPT"
}

@test "script downloads journal for comparison" {
    grep -q "rmapi get" "$SCRIPT"
}

@test "script compares file sizes to threshold" {
    grep -q "DOWNLOADED_SIZE" "$SCRIPT"
    grep -q "SIZE_THRESHOLD" "$SCRIPT"
}

@test "script removes unused journal" {
    grep -q "rmapi rm" "$SCRIPT"
}

@test "script uses stat for file size" {
    grep -q "stat" "$SCRIPT"
}
