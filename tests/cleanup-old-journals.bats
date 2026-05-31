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

@test "script short-circuits the download via cloud sizeInBytes" {
    grep -q 'EMPTY_BUNDLE_MAX_BYTES' "$SCRIPT"
    grep -q 'sizeInBytes' "$SCRIPT"
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
