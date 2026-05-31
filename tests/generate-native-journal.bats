#!/usr/bin/env bats
#
# Tests for generate-native-journal.sh
#

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$SCRIPT_DIR/generate-native-journal.sh"
}

@test "script exists and is executable" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
}

@test "script has a bash shebang" {
    head -1 "$SCRIPT" | grep -q "bash"
}

@test "script uses strict mode" {
    grep -q "set -euo pipefail" "$SCRIPT"
}

@test "blank stencil and base content assets exist" {
    [ -f "$SCRIPT_DIR/assets/blank-page.rm" ]
    [ -f "$SCRIPT_DIR/assets/base.content.json" ]
}

@test "script maps friendly template styles to device template names" {
    grep -q 'P Lines medium' "$SCRIPT"
    grep -q 'P Grid medium' "$SCRIPT"
    grep -q 'P Checklist' "$SCRIPT"
}

@test "script generates a fresh document UUID" {
    grep -q 'gen_uuid' "$SCRIPT"
}

@test "script packages a .rmdoc with zip" {
    grep -q 'zip ' "$SCRIPT"
}

@test "generates a valid lined notebook bundle" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"

    out="$BATS_TEST_TMPDIR/test.rmdoc"
    run env TEMPLATE_STYLE=lined TEMPLATE_PAGES=2 JOURNAL_NAME=test-note \
        OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    [ "$(head -c2 "$out")" = "PK" ]

    dir="$BATS_TEST_TMPDIR/x"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    # Template applied to the pages
    run jq -r '.cPages.pages[].template.value' "$dir"/*.content
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'P Lines medium'

    # Page count and .rm count agree
    [ "$(jq -r '.pageCount' "$dir"/*.content)" -eq 2 ]
    [ "$(find "$dir" -name '*.rm' | wc -l)" -eq 2 ]
}
