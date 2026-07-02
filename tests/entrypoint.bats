#!/usr/bin/env bats
#
# Tests for entrypoint.sh
#

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/entrypoint.sh"
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

@test "script defines CRON_SCHEDULE with default" {
    grep -q 'CRON_SCHEDULE=.*:-.*0 6' "$SCRIPT"
}

@test "script defines TZ with default" {
    grep -q 'TZ=.*:-' "$SCRIPT"
}

@test "script has log function" {
    grep -q "^log()" "$SCRIPT"
}

@test "script has export_env function" {
    grep -q "^export_env()" "$SCRIPT"
}

@test "script handles auth command" {
    grep -q "auth)" "$SCRIPT"
    grep -q "rmapi" "$SCRIPT"
}

@test "script handles run command" {
    grep -q "run)" "$SCRIPT"
    grep -q "cleanup-old-journals.sh" "$SCRIPT"
    grep -q "create-daily-note.sh" "$SCRIPT"
}

@test "script handles schedule command" {
    grep -q "schedule)" "$SCRIPT"
}

@test "script handles test command" {
    grep -q "test)" "$SCRIPT"
    grep -q "DRY_RUN=true" "$SCRIPT"
}

@test "script handles shell command" {
    grep -q "shell)" "$SCRIPT"
    grep -q "exec /bin/bash" "$SCRIPT"
}

@test "script shows usage for unknown commands" {
    grep -q "Usage:" "$SCRIPT"
    grep -q "Commands:" "$SCRIPT"
}

@test "script documents environment variables in help" {
    grep -q "REMARKABLE_FOLDER" "$SCRIPT"
    grep -q "DATE_FORMAT" "$SCRIPT"
    grep -q "CRON_SCHEDULE" "$SCRIPT"
}

@test "script documents cleanup settings in help" {
    grep -q "CLEANUP_ENABLED" "$SCRIPT"
    grep -q "CLEANUP_KEEP_HOURS" "$SCRIPT"
    grep -q "SIZE_THRESHOLD" "$SCRIPT"
}

@test "script exports required variables for cron" {
    grep -q "REMARKABLE_" "$SCRIPT"
    grep -q "DATE_FORMAT" "$SCRIPT"
    grep -q "CLEANUP_" "$SCRIPT"
}

@test "export_env whitelist covers TEMPLATE_ (so TEMPLATE_PDF/TEMPLATE_DOC survive to cron)" {
    grep -q "TEMPLATE_" "$SCRIPT"
}

@test "schedule command parses cron expression" {
    grep -q "CRON_MIN" "$SCRIPT"
    grep -q "CRON_HOUR" "$SCRIPT"
}

@test "schedule command has scheduler loop" {
    grep -q "while true" "$SCRIPT"
    grep -q "sleep" "$SCRIPT"
}

@test "script verifies rmapi authentication in schedule mode" {
    grep -q 'rmapi ls.*>' "$SCRIPT"
}
