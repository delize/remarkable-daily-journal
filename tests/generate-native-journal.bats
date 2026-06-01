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

@test "blank stencil is a v6 .rm file with no rmpp extras" {
    # rmscene 0.6.1 warns on SceneInfo extra_data; the cleaned stencil has it
    # stripped. Size regression-tests that: pre-clean was 409 bytes, clean is
    # 300. Anything > 350 means the rmpp scene-metadata bytes are back.
    head -c 43 "$SCRIPT_DIR/assets/blank-page.rm" \
        | grep -q '^reMarkable .lines file, version=6'
    size=$(wc -c < "$SCRIPT_DIR/assets/blank-page.rm")
    [ "$size" -lt 350 ]
}

@test "stencil's AuthorIdsBlock UUID lives at the expected offset" {
    # generate-native-journal.sh patches AUTHOR_UUID into the stencil at a
    # hardcoded offset (STENCIL_AUTHOR_UUID_OFFSET=58). If anyone regenerates
    # the stencil and the offset drifts, the patcher silently writes into the
    # wrong bytes. Pin both: the offset in the script AND that the bytes at
    # that offset match cPages.uuids[0].first in base.content.json.
    grep -q 'STENCIL_AUTHOR_UUID_OFFSET=58' "$SCRIPT_DIR/generate-native-journal.sh"
    expected_uuid="$(jq -r '.cPages.uuids[0].first' "$SCRIPT_DIR/assets/base.content.json")"
    expected_hex="${expected_uuid//-/}"
    actual_hex="$(dd if="$SCRIPT_DIR/assets/blank-page.rm" bs=1 skip=58 count=16 2>/dev/null | xxd -p -c 32)"
    [ "$expected_hex" = "$actual_hex" ]
}

@test "AUTHOR_UUID propagates to .content uuids[0].first AND stencil bytes" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/uuid.rmdoc"
    custom="feed1234-cafe-babe-dead-beefdeadbeef"
    run env AUTHOR_UUID="$custom" TEMPLATE_STYLE=lined TEMPLATE_PAGES=2 \
        JOURNAL_NAME=uuid-test OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/uuid-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    # JSON side
    [ "$(jq -r '.cPages.uuids[0].first' "$dir"/*.content)" = "$custom" ]
    [ "$(jq -r '.cPages.uuids[0].second' "$dir"/*.content)" = "1" ]

    # Every page's .rm has the new bytes at offset 58
    expected_hex="${custom//-/}"
    for f in "$dir"/*/*.rm; do
        actual_hex="$(dd if="$f" bs=1 skip=58 count=16 2>/dev/null | xxd -p -c 32)"
        [ "$expected_hex" = "$actual_hex" ]
    done
}

@test "AUTHOR_UUID defaults to a fresh random per-run UUID" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"

    a="$BATS_TEST_TMPDIR/a.rmdoc"; b="$BATS_TEST_TMPDIR/b.rmdoc"
    env TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 JOURNAL_NAME=a OUTPUT_FILE="$a" "$SCRIPT" >/dev/null
    env TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 JOURNAL_NAME=b OUTPUT_FILE="$b" "$SCRIPT" >/dev/null

    da="$BATS_TEST_TMPDIR/da"; db="$BATS_TEST_TMPDIR/db"
    mkdir -p "$da" "$db"
    unzip -oq "$a" -d "$da"
    unzip -oq "$b" -d "$db"

    ua="$(jq -r '.cPages.uuids[0].first' "$da"/*.content)"
    ub="$(jq -r '.cPages.uuids[0].first' "$db"/*.content)"

    # Both UUIDs are well-formed
    echo "$ua" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    echo "$ub" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    # And different from each other
    [ "$ua" != "$ub" ]
    # And neither is the baked stencil default (we never want to leak it).
    baked="$(jq -r '.cPages.uuids[0].first' "$SCRIPT_DIR/assets/base.content.json")"
    [ "$ua" != "$baked" ]
}

@test "rejects a malformed AUTHOR_UUID" {
    run env AUTHOR_UUID=not-a-uuid TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 \
        JOURNAL_NAME=bad OUTPUT_FILE="$BATS_TEST_TMPDIR/bad.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'AUTHOR_UUID'
}

@test "generated .content never has null cPages.pages, uuids, or pageCount" {
    # reMarkable docs that were never opened on a device can ship with null
    # cPages / pages / uuids — consumers iterating those fields crash on
    # NoneType. Our generator writes real arrays + positive pageCount on
    # every run; this test pins that so a future jq tweak can't regress us.
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/inv.rmdoc"
    run env TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 JOURNAL_NAME=inv OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/inv-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    [ "$(jq -r '.cPages.pages       | type' "$dir"/*.content)" = "array" ]
    [ "$(jq -r '.cPages.pages       | length' "$dir"/*.content)" -ge 1 ]
    [ "$(jq -r '.cPages.uuids       | type' "$dir"/*.content)" = "array" ]
    [ "$(jq -r '.cPages.uuids       | length' "$dir"/*.content)" -ge 1 ]
    [ "$(jq -r '.cPages.lastOpened  | type' "$dir"/*.content)" = "object" ]
    [ "$(jq -r '.pageCount          | type' "$dir"/*.content)" = "number" ]
    [ "$(jq -r '.pageCount' "$dir"/*.content)" -ge 1 ]
    [ "$(jq -r '.tags     | type' "$dir"/*.content)" = "array" ]
    [ "$(jq -r '.pageTags | type' "$dir"/*.content)" = "array" ]
}

@test "CREATED_TIME_MS overrides metadata timestamps and per-page modifed" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/ts.rmdoc"
    ts=1234567890000
    run env CREATED_TIME_MS="$ts" TEMPLATE_STYLE=lined TEMPLATE_PAGES=2 \
        JOURNAL_NAME=ts-test OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/ts-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"
    [ "$(jq -r '.createdTime' "$dir"/*.metadata)" = "$ts" ]
    [ "$(jq -r '.lastModified' "$dir"/*.metadata)" = "$ts" ]
    # All page modifed fields also pick up the override
    for got in $(jq -r '.cPages.pages[].modifed' "$dir"/*.content); do
        [ "$got" = "$ts" ]
    done
}

@test "script maps friendly template styles to device template names" {
    grep -q 'P Lines medium' "$SCRIPT"
    grep -q 'P Grid medium' "$SCRIPT"
    grep -q 'P Checklist' "$SCRIPT"
}

@test "script validates the template against a per-hardware list" {
    grep -q 'TEMPLATE_HARDWARE' "$SCRIPT"
    grep -q 'TEMPLATES_JSON' "$SCRIPT"
}

@test "warns on an unknown template but still generates" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/unknown.rmdoc"
    run env TEMPLATE_STYLE="Definitely Not A Template" TEMPLATE_PAGES=1 \
        JOURNAL_NAME=unknown OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    echo "$output" | grep -q 'WARNING'
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

    # cPages.lastOpened points at the first page so pages added on the device
    # inherit its template (xochitl's add-page copies from lastOpened).
    first_id="$(jq -r '.cPages.pages[0].id' "$dir"/*.content)"
    [ -n "$first_id" ] && [ "$first_id" != "null" ]
    [ "$(jq -r '.cPages.lastOpened.value' "$dir"/*.content)" = "$first_id" ]
    [ "$(jq -r '.cPages.lastOpened.timestamp' "$dir"/*.content)" = "1:1" ]
}
