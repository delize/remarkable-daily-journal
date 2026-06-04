#!/usr/bin/env bats
#
# Tests for scripts/update-templates.sh (static — the real run needs codexctl
# and a large firmware download, exercised by the scheduled workflow instead)
#

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$REPO/scripts/update-templates.sh"
}

@test "script exists and is executable" {
    [ -x "$SCRIPT" ]
}

@test "script has a bash shebang" {
    head -1 "$SCRIPT" | grep -q "bash"
}

@test "script uses strict mode" {
    grep -q "set -euo pipefail" "$SCRIPT"
}

@test "script defaults hardware to rmpp" {
    grep -q 'HARDWARE="rmpp"' "$SCRIPT"
}

@test "script accepts a --hardware argument" {
    grep -q -- '--hardware' "$SCRIPT"
}

@test "script drives codexctl list/download/cat" {
    grep -q 'codexctl list' "$SCRIPT"
    grep -q 'codexctl download' "$SCRIPT"
    grep -q 'codexctl cat' "$SCRIPT"
}

@test "script reads templates.json from the firmware image" {
    grep -q '/usr/share/remarkable/templates/templates.json' "$SCRIPT"
}
