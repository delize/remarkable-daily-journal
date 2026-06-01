#!/usr/bin/env bash
# Generate a native reMarkable notebook (.rmdoc) that references a built-in
# device template, instead of rendering a PDF with Ghostscript.
#
# The device already holds the templates, so we only reference one by name in
# the page's .content (cPages.pages[].template.value). Each page clones a blank
# v6 .rm stencil; the device draws the template background itself.
#
# Requires: jq, zip, and a v6 blank-page stencil (assets/blank-page.rm) plus a
# base content template (assets/base.content.json).
#
# Env / args:
#   TEMPLATE_STYLE   friendly alias or raw template name (default: lined)
#                      blank | lined | grid | checklist  -> mapped below
#                      anything else is passed through verbatim, so any device
#                      template works, e.g. TEMPLATE_STYLE="P Dots S"
#   TEMPLATE_PAGES   number of pages (default: 1). The device's "add page"
#                      action copies the template from cPages.lastOpened (set
#                      below to the first page), so one page is enough — pages
#                      added on the device inherit the template.
#   TEMPLATE_HARDWARE  device whose template list to validate against
#                      (default: rmpp). Picks assets/templates/<hw>.json, e.g.
#                      rmpp, rm2, rm1. Validation only warns; never blocks.
#   JOURNAL_NAME     notebook visibleName (default: today's date, YYYY-MM-DD)
#   OUTPUT_FILE      output .rmdoc path (default: ./<JOURNAL_NAME>.rmdoc)
#   AUTHOR_UUID      canonical UUID stamped into both the page's AuthorIdsBlock
#                      (.rm bytes) and cPages.uuids[0].first (.content JSON).
#                      Default: a fresh random UUID per journal. Set this to
#                      your own account's author UUID if you want every journal
#                      to be tagged as authored by you (see README for how to
#                      extract it from one of your existing notebooks).
#   CREATED_TIME_MS  millisecond epoch stamped into .metadata.createdTime,
#                      .lastModified, and per-page modifed. Default: now.
#                      Set this (e.g. from create-daily-note.sh's backfill arg)
#                      to make the journal's creation date match its name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STENCIL="${STENCIL:-$SCRIPT_DIR/assets/blank-page.rm}"
BASE_CONTENT="${BASE_CONTENT:-$SCRIPT_DIR/assets/base.content.json}"
TEMPLATE_HARDWARE="${TEMPLATE_HARDWARE:-rmpp}"
TEMPLATES_JSON="${TEMPLATES_JSON:-$SCRIPT_DIR/assets/templates/${TEMPLATE_HARDWARE}.json}"

TEMPLATE_STYLE="${TEMPLATE_STYLE:-lined}"
TEMPLATE_PAGES="${TEMPLATE_PAGES:-1}"
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

# Validate the requested template against the known list (assets/templates.json).
# This never blocks: firmware sets vary, so an unrecognised name may still be a
# real template on the device. We only warn so typos are noticed.
if [ -f "$TEMPLATES_JSON" ]; then
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

DOCID="$(gen_uuid)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$DOCID"

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
