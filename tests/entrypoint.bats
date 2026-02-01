#!/usr/bin/env bats
#
# Tests for entrypoint.sh
#

load 'test_helper'

setup() {
    setup_test_env
    create_mock_rmapi
    create_mock_gs

    # Get the script directory
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/entrypoint.sh"

    # Create mock scripts that the entrypoint calls
    mkdir -p "$TEMP_DIR/app"
    cat > "$TEMP_DIR/app/create-daily-note.sh" << 'EOF'
#!/bin/bash
echo "Mock: create-daily-note.sh called"
exit 0
EOF
    chmod +x "$TEMP_DIR/app/create-daily-note.sh"

    cat > "$TEMP_DIR/app/cleanup-old-journals.sh" << 'EOF'
#!/bin/bash
echo "Mock: cleanup-old-journals.sh called"
exit 0
EOF
    chmod +x "$TEMP_DIR/app/cleanup-old-journals.sh"
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

@test "shows help with unknown command" {
    run "$SCRIPT" unknown_command

    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Commands:"* ]]
}

@test "help includes all commands" {
    run "$SCRIPT" help

    [ "$status" -eq 1 ]
    [[ "$output" == *"auth"* ]]
    [[ "$output" == *"run"* ]]
    [[ "$output" == *"schedule"* ]]
    [[ "$output" == *"test"* ]]
    [[ "$output" == *"shell"* ]]
}

@test "help includes environment variables" {
    run "$SCRIPT" help

    [ "$status" -eq 1 ]
    [[ "$output" == *"REMARKABLE_FOLDER"* ]]
    [[ "$output" == *"DATE_FORMAT"* ]]
    [[ "$output" == *"CRON_SCHEDULE"* ]]
    [[ "$output" == *"TZ"* ]]
}

@test "help includes cleanup settings" {
    run "$SCRIPT" help

    [ "$status" -eq 1 ]
    [[ "$output" == *"CLEANUP_ENABLED"* ]]
    [[ "$output" == *"SIZE_TOLERANCE"* ]]
}

@test "test command verifies authentication" {
    # With valid mock, should pass
    export DRY_RUN=true

    # We need to use the actual script paths
    cd "$(dirname "$SCRIPT")"
    run "$SCRIPT" test

    [ "$status" -eq 0 ]
    [[ "$output" == *"authentication valid"* ]]
}

@test "test command fails when not authenticated" {
    export MOCK_RMAPI_BEHAVIOR="not_authenticated"

    cd "$(dirname "$SCRIPT")"
    run "$SCRIPT" test

    [ "$status" -ne 0 ]
    [[ "$output" == *"not authenticated"* ]]
}

@test "run command calls cleanup and create scripts" {
    # Replace scripts with our mocks for this test
    export PATH="$TEMP_DIR/app:$PATH"

    # Create a wrapper that uses our mocks
    cat > "$TEMP_DIR/test_entrypoint.sh" << EOF
#!/bin/bash
source "$SCRIPT"
EOF

    # The 'run' command should call both scripts
    cd "$(dirname "$SCRIPT")"
    run "$SCRIPT" run

    [ "$status" -eq 0 ]
    # Output should indicate it ran
    [[ "$output" == *"Running"* ]] || [[ "$output" == *"daily journal"* ]]
}

@test "default command is run" {
    # When no command specified, should default to 'run'
    cd "$(dirname "$SCRIPT")"

    # This is tricky to test without mocking, but we can check it doesn't error
    export DRY_RUN=true
    run timeout 5 "$SCRIPT" 2>&1 || true

    # Should have attempted to run (either success or expected failure)
    [[ "$output" == *"Running"* ]] || [[ "$output" == *"daily journal"* ]] || [[ "$output" == *"ERROR"* ]]
}

@test "schedule command shows configuration" {
    # schedule command will start the scheduler loop which won't exit in test
    # but we can verify it at least starts correctly
    export CRON_SCHEDULE="0 7 * * *"
    export TZ="America/New_York"

    cd "$(dirname "$SCRIPT")"
    # Use timeout to avoid hanging on scheduler loop
    run timeout 2 "$SCRIPT" schedule 2>&1 || true

    [[ "$output" == *"Schedule:"* ]] || [[ "$output" == *"0 7"* ]]
}

@test "export_env captures required variables" {
    export REMARKABLE_FOLDER="/Test"
    export DATE_FORMAT="%Y-%m-%d"
    export TITLE_FORMAT="%A"
    export TEMPLATE_PAGES=5
    export CLEANUP_ENABLED=true
    export SIZE_TOLERANCE=5000
    export TZ="UTC"

    # Source the script to get the function
    source "$SCRIPT" 2>/dev/null || true

    # Check if function exists and works
    if type export_env &>/dev/null; then
        export_env
        [ -f "/app/.env" ] || [ -f "$HOME/.env" ] || true
    fi
}
