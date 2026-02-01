#!/usr/bin/env bats
#
# Tests for cleanup-old-journals.sh
#

load 'test_helper'

setup() {
    setup_test_env
    create_mock_rmapi
    create_mock_gs

    # Get the script directory
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/cleanup-old-journals.sh"
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

@test "exits early when cleanup is disabled" {
    export CLEANUP_ENABLED=false

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleanup disabled"* ]]
}

@test "exits gracefully when rmapi not authenticated" {
    export MOCK_RMAPI_BEHAVIOR="not_authenticated"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"not authenticated"* ]]
}

@test "exits gracefully when no journal found for yesterday" {
    # Empty files.txt means no files found
    echo "" > "$MOCK_RMAPI_DATA_DIR/files.txt"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"No journal found"* ]] || [[ "$output" == *"nothing to clean up"* ]]
}

@test "keeps journal when it has content" {
    export MOCK_RMAPI_BEHAVIOR="has_content"

    # Add yesterday's file
    YESTERDAY=$(date -d "yesterday" +"$DATE_FORMAT" 2>/dev/null || date -v-1d +"$DATE_FORMAT")
    echo "[d] /Test Journal/$YESTERDAY - Test" > "$MOCK_RMAPI_DATA_DIR/files.txt"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"has been modified"* ]] || [[ "$output" == *"Keeping"* ]]
}

@test "removes journal when it is blank" {
    export MOCK_RMAPI_BEHAVIOR="blank"

    # Add yesterday's file
    YESTERDAY=$(date -d "yesterday" +"$DATE_FORMAT" 2>/dev/null || date -v-1d +"$DATE_FORMAT")
    echo "[d] /Test Journal/$YESTERDAY - Test" > "$MOCK_RMAPI_DATA_DIR/files.txt"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Should either remove it or report it as unused
    [[ "$output" == *"unused"* ]] || [[ "$output" == *"Removing"* ]] || [[ "$output" == *"Successfully removed"* ]]
}

@test "uses custom SIZE_TOLERANCE" {
    export SIZE_TOLERANCE=10000

    YESTERDAY=$(date -d "yesterday" +"$DATE_FORMAT" 2>/dev/null || date -v-1d +"$DATE_FORMAT")
    echo "[d] /Test Journal/$YESTERDAY - Test" > "$MOCK_RMAPI_DATA_DIR/files.txt"

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"tolerance: 10000"* ]]
}

@test "log function includes cleanup tag" {
    export CLEANUP_ENABLED=false

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"[cleanup]"* ]]
}

@test "uses correct date format for yesterday" {
    export DATE_FORMAT="%Y-%m-%d"

    # This should calculate yesterday correctly
    YESTERDAY=$(date -d "yesterday" +"$DATE_FORMAT" 2>/dev/null || date -v-1d +"$DATE_FORMAT")

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *"$YESTERDAY"* ]]
}

@test "handles missing REMARKABLE_FOLDER gracefully" {
    unset REMARKABLE_FOLDER

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    # Should use default
    [[ "$output" == *"/Daily Journal"* ]]
}
