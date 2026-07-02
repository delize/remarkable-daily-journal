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

#
# TEMPLATE_PDF / TEMPLATE_DOC (custom PDF page backgrounds)
#

@test "script exposes TEMPLATE_PDF and TEMPLATE_DOC" {
    grep -q 'TEMPLATE_PDF' "$SCRIPT"
    grep -q 'TEMPLATE_DOC' "$SCRIPT"
}

@test "rejects setting both TEMPLATE_PDF and TEMPLATE_DOC" {
    run env TEMPLATE_PDF="$SCRIPT_DIR/tests/fixtures/two-page.pdf" TEMPLATE_DOC=/some/cloud/path \
        JOURNAL_NAME=both OUTPUT_FILE="$BATS_TEST_TMPDIR/both.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'mutually exclusive'
}

@test "rejects a nonexistent TEMPLATE_PDF path" {
    run env TEMPLATE_PDF="$BATS_TEST_TMPDIR/does-not-exist.pdf" \
        JOURNAL_NAME=missing OUTPUT_FILE="$BATS_TEST_TMPDIR/missing.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'TEMPLATE_PDF not found'
}

@test "rejects an invalid (non-PDF) TEMPLATE_PDF" {
    command -v qpdf >/dev/null || skip "qpdf not available"
    bad="$BATS_TEST_TMPDIR/bad.pdf"
    echo "not a pdf" > "$bad"
    run env TEMPLATE_PDF="$bad" JOURNAL_NAME=bad OUTPUT_FILE="$BATS_TEST_TMPDIR/bad-out.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'PDF page count'
}

@test "TEMPLATE_PAGES <= PDF page count: every page redirects, no .rm files" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    command -v qpdf >/dev/null || skip "qpdf not available"
    out="$BATS_TEST_TMPDIR/pdf-exact.rmdoc"
    run env TEMPLATE_PDF="$SCRIPT_DIR/tests/fixtures/two-page.pdf" TEMPLATE_PAGES=2 \
        JOURNAL_NAME=pdf-exact OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/pdf-exact-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    [ "$(jq -r '.fileType' "$dir"/*.content)" = "pdf" ]
    [ "$(jq -r '.coverPageNumber' "$dir"/*.content)" = "0" ]
    [ "$(jq -r '.sizeInBytes' "$dir"/*.content)" = "$(wc -c < "$SCRIPT_DIR/tests/fixtures/two-page.pdf" | tr -d ' ')" ]
    [ "$(jq -c '[.cPages.pages[].redir.value]' "$dir"/*.content)" = "$(jq -cn '[0,1]')" ]
    [ "$(jq -r '[.cPages.pages[].template] | map(select(. != null)) | length' "$dir"/*.content)" = "0" ]
    [ "$(find "$dir" -name '*.rm' | wc -l)" -eq 0 ]

    # Embedded PDF is byte-identical to the source fixture
    cmp "$SCRIPT_DIR/tests/fixtures/two-page.pdf" "$dir"/*.pdf
}

@test "TEMPLATE_PAGES > PDF page count: overflow pages fall back to TEMPLATE_STYLE" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    command -v qpdf >/dev/null || skip "qpdf not available"
    out="$BATS_TEST_TMPDIR/pdf-overflow.rmdoc"
    run env TEMPLATE_PDF="$SCRIPT_DIR/tests/fixtures/two-page.pdf" TEMPLATE_PAGES=4 TEMPLATE_STYLE=grid \
        JOURNAL_NAME=pdf-overflow OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/pdf-overflow-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    # First 2 pages redir to PDF pages 0 and 1; last 2 fall back to the template
    [ "$(jq -r '.cPages.pages[0].redir.value' "$dir"/*.content)" = "0" ]
    [ "$(jq -r '.cPages.pages[1].redir.value' "$dir"/*.content)" = "1" ]
    [ "$(jq -r '.cPages.pages[2].template.value' "$dir"/*.content)" = "P Grid medium" ]
    [ "$(jq -r '.cPages.pages[3].template.value' "$dir"/*.content)" = "P Grid medium" ]
    [ "$(jq -r '.cPages.pages[2].redir' "$dir"/*.content)" = "null" ]
    [ "$(jq -r '.cPages.pages[0].template' "$dir"/*.content)" = "null" ]

    # Only the 2 fallback (template) pages have .rm files
    [ "$(find "$dir" -name '*.rm' | wc -l)" -eq 2 ]
}

@test "default (no PDF) path is untouched: fileType stays notebook, no sizeInBytes" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    out="$BATS_TEST_TMPDIR/no-pdf.rmdoc"
    run env TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 JOURNAL_NAME=no-pdf OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/no-pdf-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"
    [ "$(jq -r '.fileType' "$dir"/*.content)" = "notebook" ]
    [ "$(jq -r '.coverPageNumber' "$dir"/*.content)" = "-1" ]
    [ "$(jq -e 'has("sizeInBytes")' "$dir"/*.content)" = "false" ]
}

# Builds a minimal PDF-backed .rmdoc bundle (fileType:"pdf", one redir page,
# embedded two-page.pdf) to stand in for "a document already on the tablet",
# without depending on generate-native-journal.sh itself.
build_pdf_doc_fixture() {
    local out="$1" work id pid
    work="$BATS_TEST_TMPDIR/doc-fixture-src"
    mkdir -p "$work/tmp"
    id="11111111-1111-1111-1111-111111111111"
    pid="22222222-2222-2222-2222-222222222222"
    jq -n --arg id "$pid" \
      '{cPages: {pages: [{id: $id, idx: {timestamp:"1:1", value:"ba"}, redir: {timestamp:"1:1", value:0}}],
                 lastOpened: {timestamp:"1:1", value: $id}, uuids: [{first:"00000000-0000-0000-0000-000000000000", second:1}]},
        fileType: "pdf", pageCount: 1, coverPageNumber: 0, orientation: "portrait"}' \
      > "$work/tmp/$id.content"
    jq -n --arg name "doc-fixture" \
      '{createdTime:"0", lastModified:"0", lastOpened:"0", lastOpenedPage:-1, new:false, parent:"", pinned:false, source:"", type:"DocumentType", visibleName:$name}' \
      > "$work/tmp/$id.metadata"
    cp "$SCRIPT_DIR/tests/fixtures/two-page.pdf" "$work/tmp/$id.pdf"
    ( cd "$work/tmp" && zip -r -X -q "$out" "$id.content" "$id.metadata" "$id.pdf" )
}

@test "TEMPLATE_DOC fetches an existing PDF-backed document via rmapi and reuses its PDF" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    command -v qpdf >/dev/null || skip "qpdf not available"

    fixture="$BATS_TEST_TMPDIR/doc-fixture.rmdoc"
    build_pdf_doc_fixture "$fixture"

    stub_dir="$BATS_TEST_TMPDIR/stub-bin"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/rmapi" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "get" ]; then
  cp "$fixture" "./\$(basename "\$2").rmdoc"
  exit 0
fi
exit 1
EOF
    chmod +x "$stub_dir/rmapi"

    out="$BATS_TEST_TMPDIR/via-doc.rmdoc"
    run env PATH="$stub_dir:$PATH" TEMPLATE_DOC="/Templates/My PDF Notebook" TEMPLATE_PAGES=1 \
        JOURNAL_NAME=via-doc OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/via-doc-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"
    [ "$(jq -r '.fileType' "$dir"/*.content)" = "pdf" ]
    cmp "$SCRIPT_DIR/tests/fixtures/two-page.pdf" "$dir"/*.pdf
}

@test "TEMPLATE_PDF accepts a PNG, auto-wrapping it into a 1-page PDF" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"
    command -v qpdf >/dev/null || skip "qpdf not available"
    command -v img2pdf >/dev/null || skip "img2pdf not available"

    out="$BATS_TEST_TMPDIR/png-test.rmdoc"
    run env TEMPLATE_PDF="$SCRIPT_DIR/tests/fixtures/test-template.png" TEMPLATE_PAGES=1 \
        JOURNAL_NAME=png-test OUTPUT_FILE="$out" "$SCRIPT"
    [ "$status" -eq 0 ]
    dir="$BATS_TEST_TMPDIR/png-test-unpacked"
    mkdir -p "$dir"
    unzip -oq "$out" -d "$dir"

    [ "$(jq -r '.fileType' "$dir"/*.content)" = "pdf" ]
    [ "$(jq -r '.cPages.pages[0].redir.value' "$dir"/*.content)" = "0" ]
    [ "$(find "$dir" -name '*.rm' | wc -l)" -eq 0 ]
    head -c5 "$dir"/*.pdf | grep -q '^%PDF-'
}

@test "TEMPLATE_PDF rejects an invalid PNG/JPG image" {
    command -v img2pdf >/dev/null || skip "img2pdf not available"
    bad="$BATS_TEST_TMPDIR/bad.png"
    echo "not an image" > "$bad"
    run env TEMPLATE_PDF="$bad" JOURNAL_NAME=badpng OUTPUT_FILE="$BATS_TEST_TMPDIR/badpng.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'img2pdf failed to convert TEMPLATE_PDF'
}

@test "TEMPLATE_DOC errors clearly when the fetched document has no embedded PDF" {
    command -v zip >/dev/null || skip "zip not available"
    command -v jq >/dev/null || skip "jq not available"

    # Build a plain notebook bundle (no .pdf inside) to stand in for a
    # non-PDF-backed document already on the tablet.
    plain="$BATS_TEST_TMPDIR/plain-notebook.rmdoc"
    run env TEMPLATE_STYLE=lined TEMPLATE_PAGES=1 JOURNAL_NAME=plain OUTPUT_FILE="$plain" "$SCRIPT"
    [ "$status" -eq 0 ]

    stub_dir="$BATS_TEST_TMPDIR/stub-bin2"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/rmapi" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "get" ]; then
  cp "$plain" "./\$(basename "\$2").rmdoc"
  exit 0
fi
exit 1
EOF
    chmod +x "$stub_dir/rmapi"

    run env PATH="$stub_dir:$PATH" TEMPLATE_DOC="/Templates/Plain Notebook" \
        JOURNAL_NAME=via-doc-bad OUTPUT_FILE="$BATS_TEST_TMPDIR/via-doc-bad.rmdoc" "$SCRIPT"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qi 'no embedded PDF'
}
