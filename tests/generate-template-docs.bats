#!/usr/bin/env bats
#
# Tests for scripts/generate-template-docs.sh and the canonical template list
#

setup() {
    REPO="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
    SCRIPT="$REPO/scripts/generate-template-docs.sh"
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

@test "canonical rmpp template list is valid and has the alias targets" {
    command -v jq >/dev/null || skip "jq not available"
    J="$REPO/assets/templates/rmpp.json"
    jq empty "$J"
    for t in "Blank" "P Lines medium" "P Grid medium" "P Checklist"; do
        jq -e --arg t "$t" 'any(.templates[]; .filename == $t)' "$J" >/dev/null
    done
}

@test "regenerates a doc with portrait and landscape sections" {
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/out.md"
    run "$SCRIPT" "$REPO/assets/templates/rmpp.json" "$out"
    [ "$status" -eq 0 ]
    grep -q 'Portrait templates' "$out"
    grep -q 'Landscape templates' "$out"
    grep -q 'P Lines medium' "$out"
}
