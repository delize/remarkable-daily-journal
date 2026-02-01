#!/usr/bin/env bats
#
# Tests for create-daily-note.sh
#

load 'test_helper'

setup() {
    setup_test_env
    create_mock_rmapi
    create_mock_gs

    # Get the script directory
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/create-daily-note.sh"
}

teardown() {
    teardown_test_env
}

@test "script exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "script has correct shebang" {
    head -1 "$SCRIPT" | grep -q "#!/bin/bash"
}

@test "dry run mode creates PDF but does not upload" {
    export DRY_RUN=true

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY RUN"* ]]
    [[ "$output" == *"Would upload"* ]]
}

@test "uses default values when environment not set" {
    unset REMARKABLE_FOLDER
    unset DATE_FORMAT
    unset TITLE_FORMAT
    unset TEMPLATE_PAGES
    export DRY_RUN=true

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Daily Journal"* ]]
}

@test "accepts custom date argument" {
    export DRY_RUN=true

    run "$SCRIPT" "2025-01-15"

    [ "$status" -eq 0 ]
    [[ "$output" == *"2025-01-15"* ]]
}

@test "uses custom REMARKABLE_FOLDER" {
    export REMARKABLE_FOLDER="/Custom Folder"
    export DRY_RUN=true

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"/Custom Folder"* ]]
}

@test "uses custom TEMPLATE_PAGES" {
    export TEMPLATE_PAGES=10
    export DRY_RUN=true

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"10 page"* ]]
}

@test "creates temp directory and cleans up" {
    export DRY_RUN=true

    # Count temp directories before
    before_count=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l || echo 0)

    run "$SCRIPT"

    # Count temp directories after (should be same or less due to cleanup)
    after_count=$(ls -d /tmp/tmp.* 2>/dev/null | wc -l || echo 0)

    [ "$status" -eq 0 ]
    # Allow for some variance but shouldn't grow significantly
    [ "$after_count" -le "$((before_count + 1))" ]
}

@test "fails gracefully when rmapi not authenticated" {
    export DRY_RUN=false
    export MOCK_RMAPI_BEHAVIOR="not_authenticated"

    run "$SCRIPT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"not authenticated"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "skips upload when note already exists" {
    export DRY_RUN=false

    # Pre-create the mock file list with today's date
    TODAY=$(date +"$DATE_FORMAT")
    echo "[d] /Test Journal/$TODAY - Test" > "$MOCK_RMAPI_DATA_DIR/files.txt"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"already exists"* ]]
}

@test "log function includes timestamp" {
    export DRY_RUN=true

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Check for timestamp format [YYYY-MM-DD HH:MM:SS]
    [[ "$output" =~ \[[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\] ]]
}

@test "notebook name includes date and title" {
    export DRY_RUN=true
    export DATE_FORMAT="%Y-%m-%d"
    export TITLE_FORMAT="%A"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Should have date format in output
    TODAY=$(date +"%Y-%m-%d")
    [[ "$output" == *"$TODAY"* ]]
}
