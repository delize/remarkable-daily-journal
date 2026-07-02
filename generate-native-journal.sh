#!/usr/bin/env bash
# Generate a native reMarkable notebook (.rmdoc) that references a built-in
# device template, instead of rendering a PDF with Ghostscript.
#
# Optionally, TEMPLATE_PDF/TEMPLATE_DOC swap the page background for a real
# user-supplied PDF (or a PNG/JPG, auto-wrapped into a PDF via img2pdf).
#
# SAFETY NOTE (read before touching TEMPLATE_PDF/TEMPLATE_DOC): an earlier
# version of this feature hand-built reMarkable's per-page sync structure
# (cPages.pages[] with redir/template entries) on a document that had never
# been opened by the tablet, and that crash-looped a real device. cPages is
# CRDT sync state the device itself is supposed to construct, not something
# safe to precompute and ship cold. See
# docs/decisions/0001-custom-pdf-page-backgrounds.md for the incident.
#
# The default behavior now matches `rmapi put somefile.pdf` exactly — the
# proven-safe path millions of rmapi users already rely on: the resolved PDF
# is written out as a plain .pdf file (not a notebook bundle), with NO
# hand-built cPages/redir at all. The tablet lazily constructs its own page
# structure the first time a human opens it, same as any normal PDF import.
#
# TEMPLATE_PDF_NATIVE_EXPERIMENTAL=true switches to an EXPERIMENTAL variant
# that still builds our own .rmdoc bundle (so AUTHOR_UUID/CREATED_TIME_MS
# backfill still work), but leaves cPages entirely at its pristine, empty
# "never opened" default — no page loop, no redir/template entries. This is
# a new, less-tested hypothesis than the default path: only the CRDT page
# array was implicated in the crash, and this variant never builds one, but
# it has NOT been independently verified on real hardware. Off by default.
#
# The device already holds the templates, so we only reference one by name in
# the page's .content (cPages.pages[].template.value). Each page clones a blank
# v6 .rm stencil; the device draws the template background itself.
#
# Requires: jq, zip, and a v6 blank-page stencil (assets/blank-page.rm) plus a
# base content template (assets/base.content.json). img2pdf is required only
# to wrap a PNG/JPG TEMPLATE_PDF. qpdf is optional (used only for a cosmetic
# page-count in the experimental native variant); nothing requires it to be
# accurate or even present.
#
# Env / args:
#   TEMPLATE_STYLE   friendly alias or raw template name (default: lined)
#                      blank | lined | grid | checklist  -> mapped below
#                      anything else is passed through verbatim, so any device
#                      template works, e.g. TEMPLATE_STYLE="P Dots S"
#   TEMPLATE_PAGES   number of pages (default: 1). Ignored when TEMPLATE_PDF/
#                      TEMPLATE_DOC is set (see above — the tablet decides its
#                      own page structure for a PDF-backed document).
#   TEMPLATE_HARDWARE  device whose template list to validate against
#                      (default: rmpp). Picks assets/templates/<hw>.json, e.g.
#                      rmpp, rm2, rm1. Validation only warns; never blocks.
#   TEMPLATE_PDF     path to a PDF (or a PNG/JPG image, auto-wrapped into a
#                      1-page PDF via img2pdf) to use as the journal's page
#                      background, instead of a built-in template. Mutually
#                      exclusive with TEMPLATE_DOC.
#   TEMPLATE_DOC     cloud path (rmapi) of an existing PDF-backed document to
#                      reuse as the page background; fetched with `rmapi get`.
#                      Errors if the fetched document has no embedded PDF.
#                      Mutually exclusive with TEMPLATE_PDF.
#   TEMPLATE_PDF_NATIVE_EXPERIMENTAL
#                    "true" to use the experimental native-.rmdoc variant
#                      described above, instead of the default plain-PDF
#                      passthrough. Default: false. No effect unless
#                      TEMPLATE_PDF/TEMPLATE_DOC is also set.
#   JOURNAL_NAME     notebook visibleName (default: today's date, YYYY-MM-DD)
#   OUTPUT_FILE      output path (default: ./<JOURNAL_NAME>.rmdoc). When a PDF
#                      is in play and TEMPLATE_PDF_NATIVE_EXPERIMENTAL is not
#                      set, the actual output is always written with a .pdf
#                      extension regardless of what's requested here (rmapi
#                      dispatches upload behavior from the file extension).
#   AUTHOR_UUID      canonical UUID stamped into both the page's AuthorIdsBlock
#                      (.rm bytes) and cPages.uuids[0].first (.content JSON).
#                      Default: a fresh random UUID per journal. Set this to
#                      your own account's author UUID if you want every journal
#                      to be tagged as authored by you (see README for how to
#                      extract it from one of your existing notebooks). Not
#                      used in the default plain-PDF-passthrough mode.
#   CREATED_TIME_MS  millisecond epoch stamped into .metadata.createdTime,
#                      .lastModified, and per-page modifed. Default: now.
#                      Set this (e.g. from create-daily-note.sh's backfill arg)
#                      to make the journal's creation date match its name. Not
#                      used in the default plain-PDF-passthrough mode.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STENCIL="${STENCIL:-$SCRIPT_DIR/assets/blank-page.rm}"
BASE_CONTENT="${BASE_CONTENT:-$SCRIPT_DIR/assets/base.content.json}"
TEMPLATE_HARDWARE="${TEMPLATE_HARDWARE:-rmpp}"
TEMPLATES_JSON="${TEMPLATES_JSON:-$SCRIPT_DIR/assets/templates/${TEMPLATE_HARDWARE}.json}"

TEMPLATE_STYLE="${TEMPLATE_STYLE:-lined}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-1}"
TEMPLATE_PDF="${TEMPLATE_PDF:-}"
TEMPLATE_DOC="${TEMPLATE_DOC:-}"
TEMPLATE_PDF_NATIVE_EXPERIMENTAL="${TEMPLATE_PDF_NATIVE_EXPERIMENTAL:-false}"
JOURNAL_NAME="${JOURNAL_NAME:-$(date +%Y-%m-%d)}"
OUTPUT_FILE="${OUTPUT_FILE:-./${JOURNAL_NAME}.rmdoc}"

# Map a friendly style to the device's template reference. Unknown values are
# passed through verbatim so any of the device's ~100 templates can be used.
case "$TEMPLATE_STYLE" in
  blank)     RM_TEMPLATE="Blank" ;;
  lined)     RM_TEMPLATE="P Lines medium" ;;
  grid)      RM_TEMPLATE="P Grid medium" ;;
  checklist) RM_TEMPLATE="P Checklist" ;;
  *)         RM_TEMPLATE="$TEMPLATE_STYLE" ;;
esac

for dep in jq zip; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' not found" >&2; exit 1; }
done
[ -f "$STENCIL" ] || { echo "ERROR: stencil not found: $STENCIL" >&2; exit 1; }
[ -f "$BASE_CONTENT" ] || { echo "ERROR: base content not found: $BASE_CONTENT" >&2; exit 1; }

if [ -n "$TEMPLATE_PDF" ] && [ -n "$TEMPLATE_DOC" ]; then
  echo "ERROR: TEMPLATE_PDF and TEMPLATE_DOC are mutually exclusive" >&2
  exit 1
fi

# Validate the requested template against the known list (assets/templates.json).
# This never blocks: firmware sets vary, so an unrecognised name may still be a
# real template on the device. We only warn so typos are noticed. Skipped
# entirely once a PDF is in play (no built-in template is referenced then).
if [ -z "$TEMPLATE_PDF" ] && [ -z "$TEMPLATE_DOC" ] && [ -f "$TEMPLATES_JSON" ]; then
  if jq -e --arg t "$RM_TEMPLATE" 'any(.templates[]; .filename == $t)' "$TEMPLATES_JSON" >/dev/null 2>&1; then
    : # known template
  else
    echo "WARNING: template '$RM_TEMPLATE' is not in $TEMPLATES_JSON." >&2
    echo "         Using it anyway; if the device lacks it the page renders blank." >&2
    echo "         See docs/templates/${TEMPLATE_HARDWARE}.md for valid template names." >&2
  fi
fi

gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

DOCID="$(gen_uuid)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$DOCID"

# Resolve TEMPLATE_PDF/TEMPLATE_DOC into a local PDF_PATH, if either is set.
# TEMPLATE_DOC fetches an existing cloud document via rmapi and reuses its
# embedded PDF; TEMPLATE_PDF just points straight at a mounted file.
PDF_PATH=""
if [ -n "$TEMPLATE_PDF" ]; then
  [ -f "$TEMPLATE_PDF" ] || { echo "ERROR: TEMPLATE_PDF not found: $TEMPLATE_PDF" >&2; exit 1; }
  case "$(printf '%s' "$TEMPLATE_PDF" | tr '[:upper:]' '[:lower:]')" in
    *.png|*.jpg|*.jpeg)
      command -v img2pdf >/dev/null 2>&1 || { echo "ERROR: 'img2pdf' not found (required to wrap a PNG/JPG TEMPLATE_PDF)" >&2; exit 1; }
      WRAPPED_PDF="$WORK/wrapped-input.pdf"
      img2pdf "$TEMPLATE_PDF" -o "$WRAPPED_PDF" \
        || { echo "ERROR: img2pdf failed to convert TEMPLATE_PDF to PDF: $TEMPLATE_PDF (see its message above)" >&2; exit 1; }
      PDF_PATH="$WRAPPED_PDF"
      ;;
    *)
      PDF_PATH="$TEMPLATE_PDF"
      ;;
  esac
elif [ -n "$TEMPLATE_DOC" ]; then
  command -v rmapi >/dev/null 2>&1 || { echo "ERROR: 'rmapi' not found (required for TEMPLATE_DOC)" >&2; exit 1; }
  FETCH_DIR="$WORK/fetch"
  mkdir -p "$FETCH_DIR"
  if ! (cd "$FETCH_DIR" && rmapi get "$TEMPLATE_DOC") >&2; then
    echo "ERROR: 'rmapi get' failed for TEMPLATE_DOC: $TEMPLATE_DOC" >&2
    exit 1
  fi
  BUNDLE="$(find "$FETCH_DIR" -maxdepth 1 -type f \( -name '*.rmdoc' -o -name '*.zip' \) | head -n1)"
  [ -n "$BUNDLE" ] || { echo "ERROR: TEMPLATE_DOC fetch produced no bundle: $TEMPLATE_DOC" >&2; exit 1; }
  UNPACK_DIR="$FETCH_DIR/unpacked"
  mkdir -p "$UNPACK_DIR"
  unzip -oq "$BUNDLE" -d "$UNPACK_DIR"
  SRC_PDF="$(find "$UNPACK_DIR" -maxdepth 1 -name '*.pdf' | head -n1)"
  if [ -z "$SRC_PDF" ]; then
    echo "ERROR: TEMPLATE_DOC has no embedded PDF — it's a notebook, not a PDF-backed document: $TEMPLATE_DOC" >&2
    exit 1
  fi
  PDF_PATH="$SRC_PDF"
fi

if [ -n "$PDF_PATH" ]; then
  head -c5 "$PDF_PATH" | grep -q '^%PDF-' \
    || { echo "ERROR: resolved PDF source doesn't look like a PDF (missing %PDF- header): $PDF_PATH" >&2; exit 1; }
fi

###############################################################################
# Default, proven-safe path: TEMPLATE_PDF/TEMPLATE_DOC without the
# experimental flag just writes out a plain .pdf file. No custom bundle, no
# hand-built cPages — identical in spirit to `rmapi put somefile.pdf`.
###############################################################################
if [ -n "$PDF_PATH" ] && [ "$TEMPLATE_PDF_NATIVE_EXPERIMENTAL" != "true" ]; then
  OUT_ABS="$(cd "$(dirname "$OUTPUT_FILE")" && pwd)/$(basename "$OUTPUT_FILE")"
  REAL_OUT="${OUT_ABS%.*}.pdf"
  if [ "$REAL_OUT" != "$OUT_ABS" ]; then
    echo "NOTE: writing $REAL_OUT (not $OUT_ABS) — a plain PDF, not a notebook bundle." >&2
  fi
  rm -f "$REAL_OUT"
  cp "$PDF_PATH" "$REAL_OUT"
  echo "Generated: $REAL_OUT"
  echo "  name=$JOURNAL_NAME  pdf=$PDF_PATH  (plain PDF passthrough; upload with rmapi put, same as any PDF import)"
  exit 0
fi

if [ -n "$PDF_PATH" ]; then
  echo "WARNING: TEMPLATE_PDF_NATIVE_EXPERIMENTAL=true — building a hand-crafted native .rmdoc bundle." >&2
  echo "         This variant has not been independently verified on real hardware. See" >&2
  echo "         docs/decisions/0001-custom-pdf-page-backgrounds.md before trusting it." >&2
fi

# Resolve and validate the author UUID. Default: a fresh random one per
# journal so we never leak the stencil's baked identity into the cloud.
AUTHOR_UUID="${AUTHOR_UUID:-$(gen_uuid)}"
if ! [[ "$AUTHOR_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "ERROR: AUTHOR_UUID is not a canonical UUID: $AUTHOR_UUID" >&2
  exit 1
fi
AUTHOR_UUID="$(echo "$AUTHOR_UUID" | tr 'A-Z' 'a-z')"

# Stamp time. Default: now. create-daily-note.sh overrides this when given
# a backfill date so createdTime matches the journal's name.
CREATED_TIME_MS="${CREATED_TIME_MS:-$(date +%s)000}"
if ! [[ "$CREATED_TIME_MS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CREATED_TIME_MS must be a millisecond epoch: $CREATED_TIME_MS" >&2
  exit 1
fi

# Byte offset of the AuthorIdsBlock UUID inside the v6 stencil. The 16 bytes
# starting here are the only place the per-document author identity is stored
# in raw form. Verified against assets/blank-page.rm; tests/generate-native-
# journal.bats keeps it honest if the stencil is ever regenerated.
STENCIL_AUTHOR_UUID_OFFSET=58

# Overwrite the stencil's baked UUID with AUTHOR_UUID's 16 raw bytes
# (canonical order — matches what the .content JSON shows as
# cPages.uuids[0].first). The stencil and .content thus reference the same
# identity end-to-end.
patch_stencil_uuid() {
  local in="$1" out="$2" uuid_hex escaped
  uuid_hex="${AUTHOR_UUID//-/}"
  cp "$in" "$out"
  # Convert "feed1234..." -> the escape string "\xfe\xed\x12\x34..." with sed,
  # then have printf interpret the escapes into raw bytes for dd to drop into
  # the stencil at the AuthorIdsBlock offset.
  escaped="$(printf '%s' "$uuid_hex" | sed 's/../\\x&/g')"
  printf '%b' "$escaped" \
    | dd of="$out" bs=1 seek="$STENCIL_AUTHOR_UUID_OFFSET" count=16 \
        conv=notrunc status=none
}

# reMarkable fractional-index ordering key for the i-th page (1-based).
# Two base-62 chars (ASCII order: 0-9 A-Z a-z). Page 1 == "ba", matching what
# the device itself writes; equal-length keys sort lexicographically = order.
ALPHA='0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
idx_key() {
  local num=$(( 2330 + $1 - 1 ))   # 2330 == "ba"
  echo "${ALPHA:$((num/62)):1}${ALPHA:$((num%62)):1}"
}

if [ -n "$PDF_PATH" ]; then
  # Experimental native-PDF-bundle variant: NO page loop, NO cPages
  # population at all. cPages stays at assets/base.content.json's pristine
  # empty default (pages: [], lastOpened: {timestamp:"0:0",value:""}) —
  # exactly the "never opened yet" shape a real device would start from,
  # matching what rmapi's own raw-PDF upload leaves for the tablet to build
  # itself. We only touch scalar document properties, never per-page sync
  # state.
  PDF_SIZE_BYTES="$(wc -c < "$PDF_PATH" | tr -d ' ')"
  PDF_PAGE_COUNT=1
  if command -v qpdf >/dev/null 2>&1; then
    PDF_PAGE_COUNT="$(qpdf --show-npages "$PDF_PATH" 2>/dev/null || echo 1)"
  fi

  jq --arg uuid "$AUTHOR_UUID" --arg size "$PDF_SIZE_BYTES" --argjson n "$PDF_PAGE_COUNT" \
    '.cPages.uuids = [ { first: $uuid, second: 1 } ]
     | .fileType = "pdf"
     | .pageCount = $n
     | .sizeInBytes = $size' \
    "$BASE_CONTENT" > "$WORK/$DOCID.content"

  jq -n --arg name "$JOURNAL_NAME" --arg ts "$CREATED_TIME_MS" \
    '{
       createdTime: $ts, lastModified: $ts, lastOpened: "0", lastOpenedPage: -1,
       new: true, parent: "", pinned: false, source: "",
       type: "DocumentType", visibleName: $name
     }' > "$WORK/$DOCID.metadata"

  cp "$PDF_PATH" "$WORK/$DOCID.pdf"

  OUT_ABS="$(cd "$(dirname "$OUTPUT_FILE")" && pwd)/$(basename "$OUTPUT_FILE")"
  rm -f "$OUT_ABS"
  ( cd "$WORK" && zip -r -X -q "$OUT_ABS" "$DOCID.content" "$DOCID.metadata" "$DOCID.pdf" )

  echo "Generated: $OUT_ABS (EXPERIMENTAL native PDF bundle, unverified on hardware)"
  echo "  name=$JOURNAL_NAME  pdf=$PDF_PATH (pdf_pages=$PDF_PAGE_COUNT)  doc=$DOCID"
  echo "  author=$AUTHOR_UUID  createdTime=$CREATED_TIME_MS"
  exit 0
fi

###############################################################################
# Default notebook path (no PDF at all): unchanged from before.
###############################################################################

# Build the pages array, cloning the stencil (with AUTHOR_UUID patched in)
# for each page.
pages='[]'
for i in $(seq 1 "$TEMPLATE_PAGES"); do
  pid="$(gen_uuid)"
  patch_stencil_uuid "$STENCIL" "$WORK/$DOCID/$pid.rm"
  pages="$(jq \
    --arg id "$pid" --arg idx "$(idx_key "$i")" \
    --arg tmpl "$RM_TEMPLATE" --arg ts "$CREATED_TIME_MS" \
    '. += [{
       id: $id,
       idx:      { timestamp: "1:2", value: $idx },
       modifed:  $ts,
       template: { timestamp: "1:1", value: $tmpl }
     }]' <<<"$pages")"
done

# .content: inject pages + count into the known-good base template, point
# cPages.lastOpened at the first page so pages added on the device inherit
# its template (xochitl's add-page copies the template from lastOpened's
# page), and stamp cPages.uuids[0].first with the same identity that we
# wrote into the stencil's AuthorIdsBlock.
jq --argjson pages "$pages" --argjson n "$TEMPLATE_PAGES" --arg uuid "$AUTHOR_UUID" \
  '.cPages.pages = $pages
   | .cPages.lastOpened = { timestamp: "1:1", value: $pages[0].id }
   | .cPages.uuids = [ { first: $uuid, second: 1 } ]
   | .pageCount = $n' \
  "$BASE_CONTENT" > "$WORK/$DOCID.content"

# .metadata
jq -n --arg name "$JOURNAL_NAME" --arg ts "$CREATED_TIME_MS" \
  '{
     createdTime: $ts, lastModified: $ts, lastOpened: "0", lastOpenedPage: -1,
     new: true, parent: "", pinned: false, source: "",
     type: "DocumentType", visibleName: $name
   }' > "$WORK/$DOCID.metadata"

# Package as a flat .rmdoc (zip with files at the root).
OUT_ABS="$(cd "$(dirname "$OUTPUT_FILE")" && pwd)/$(basename "$OUTPUT_FILE")"
rm -f "$OUT_ABS"
( cd "$WORK" && zip -r -X -q "$OUT_ABS" "$DOCID.content" "$DOCID.metadata" "$DOCID" )

echo "Generated: $OUT_ABS"
echo "  name=$JOURNAL_NAME  template=$RM_TEMPLATE  pages=$TEMPLATE_PAGES  doc=$DOCID"
echo "  author=$AUTHOR_UUID  createdTime=$CREATED_TIME_MS"
