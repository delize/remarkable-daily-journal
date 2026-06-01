# Fixing five small things in remarkable-daily-journal

*2026-06-01*

The journals this container generates have been mostly working for a while, but
a handful of bugs only show up once you live with them daily. This post walks
through the five fixes that landed today (PRs [#5][pr5], [#6][pr6], [#7][pr7],
[#8][pr8], [#9][pr9]), the symptoms that led to each, and the firmware
spelunking it took to find the underlying cause.

[pr5]: https://github.com/delize/remarkable-daily-journal/pull/5
[pr6]: https://github.com/delize/remarkable-daily-journal/pull/6
[pr7]: https://github.com/delize/remarkable-daily-journal/pull/7
[pr8]: https://github.com/delize/remarkable-daily-journal/pull/8
[pr9]: https://github.com/delize/remarkable-daily-journal/pull/9

## 1. New pages on the device came up blank ([#5][pr5])

The reported symptom: open today's journal, tap "+" to add a page, the new
page is blank. The first page has the right template; nothing after page one
does.

The script's comment claimed the device would automatically copy the previous
page's template. That turned out to be wishful thinking. Strings from the
extracted `xochitl` binary showed the actual call:

```
addPageWithTemplateAndPaperSizeFromPage
```

"From a page" — singular, a specific source. So the question became: *which*
page does it copy from?

We diffed our generator's output against a freshly device-created notebook
("Notebook 2") pulled down with `rmapi get`. Everything matched except one
field inside `.content`:

```jsonc
// device-created
"cPages": {
  "lastOpened": { "timestamp": "1:2", "value": "<page UUID>" }
}

// ours
"cPages": {
  "lastOpened": { "timestamp": "0:0", "value": "" }
}
```

Our `lastOpened` was empty. `xochitl`'s add-page action evidently copies the
template from whichever page `cPages.lastOpened` points to, and on first open
of an empty-`lastOpened` document, there's no source page to copy from. The
new page comes up blank.

The fix: when building the bundle, point `cPages.lastOpened.value` at the first
generated page's UUID. One added line in `generate-native-journal.sh`:

```bash
jq --argjson pages "$pages" --argjson n "$TEMPLATE_PAGES" \
  '.cPages.pages = $pages
   | .cPages.lastOpened = { timestamp: "1:1", value: $pages[0].id }
   | .pageCount = $n' \
  "$BASE_CONTENT" > "$WORK/$DOCID.content"
```

## 2. Every upload landed as a notebook called "journal" ([#6][pr6])

Right after PR #5 went out, the user noticed every notebook was showing up on
the device as plain "journal", regardless of the date.

`rmapi put` takes the cloud `visibleName` from the file's **basename**, not from
the `.metadata` inside the `.rmdoc` bundle. The temp file was hardcoded:

```bash
RMDOC_FILE="$TEMP_DIR/journal.rmdoc"
```

So no matter what we wrote in `metadata.visibleName`, the upload was always
named "journal".

Fix: name the temp file after `JOURNAL_NAME`, with `/` replaced by `-` so an
exotic `JOURNAL_NAME_FORMAT` can't escape the temp dir:

```bash
SAFE_NAME="${JOURNAL_NAME//\//-}"
RMDOC_FILE="$TEMP_DIR/$SAFE_NAME.rmdoc"
```

## 3. Cleanup was redownloading every old journal, every cycle ([#7][pr7])

A quick container restart showed the cleanup pass downloading 5+ months of
historic journals just to verify their `.rm` layer sizes:

```
[cleanup] Checking: 2026-01-18 (stale, verifying contents)
[cleanup]   rmapi get exit=0 output: downloading...
[cleanup]   Largest .rm layer: 262544 bytes (empty threshold: 1000)
[cleanup]   Journal has writing, keeping
[cleanup] Checking: 2026-01-19 (stale, verifying contents)
... and so on for every old journal
```

The original policy was "delete journals older than 48h that are also empty,"
which meant *every* old journal had to be inspected on every cycle to confirm
it had writing. That's the wrong default for daily journals — once you've
written in one, it's never going to become "empty"; that work is pure waste.

Three changes:

- **Flip the window.** Only journals *younger* than `CLEANUP_KEEP_HOURS` are
  even considered for deletion. Anything older is settled forever — no
  download, no inspection. A daily journal that survives past the window stays
  forever.
- **Cloud-size short-circuit.** `rmapi stat` returns `sizeInBytes`. Empty
  generated bundles are ~6KB; anything with strokes blows well past 50KB. If
  the cloud already reports a big bundle, treat it as written-on and skip the
  download.
- **Persistent verified-non-empty cache.** A tsv of `{name → ModifiedClient}`
  lives in the existing rmapi-config volume. Subsequent runs that see the
  same `ModifiedClient` skip the download outright.

Together, the cleanup pass now only ever downloads a journal at most once,
and only inside its 48h window.

## 4. JOURNAL_NAME=foo was silently ignored ([#8][pr8])

While testing PR #6, the user tried to force a recognizable name on the
upload:

```bash
docker exec -e JOURNAL_NAME=template-fix-test remarkable-daily-journal /app/create-daily-note.sh
```

…and got back today's date. The script always overwrote `JOURNAL_NAME` with
its own computation. Quick fix:

```bash
if [ -n "${1:-}" ]; then
    JOURNAL_NAME=$(date -d "$1" +"$JOURNAL_NAME_FORMAT")
elif [ -z "${JOURNAL_NAME:-}" ]; then
    JOURNAL_NAME=$(date +"$JOURNAL_NAME_FORMAT")
fi
```

Three layers of control now, in priority order:

| You want | Set |
|----------|-----|
| Arbitrary literal name | `JOURNAL_NAME=anything-here` |
| Today's date with extra text | `JOURNAL_NAME_FORMAT="Journal %Y-%m-%d"` |
| Plain today's date (default) | leave both unset |
| A specific past date | positional arg: `./create-daily-note.sh 2026-01-15` |

## 5. rmscene warned on every generated `.rm` ([#9][pr9])

When the user tried to convert a generated journal to PDF with `rmc`, every
parse logged:

> WARNING:rmscene.tagged_block_reader: Some data has not been read. The data
> may have been written using a newer format than this reader supports.

Worrying-looking but not actually corrupting. We dumped the block structure
with `rmc -t blocks` and traced the warning to exactly one block in the
stencil:

```
SceneInfo(extra_data=b'\\\x08\x00\x00\x00T\x06\x00\x00p\x08\x00\x00...',
          current_layer=...,
          background_visible=...,
          root_document_visible=...)
```

109 trailing bytes inside `SceneInfo`. The stencil had been captured from a
Paper Pro, and the rmpp firmware writes scene-render-time state (custom-zoom
parameters, tool state, etc.) past what rmscene 0.6.1 knows how to decode.

We round-tripped the stencil through rmscene with `extra_data` cleared:

```python
blocks = list(read_blocks(io.BytesIO(src)))
for b in blocks:
    if isinstance(b, SceneInfo):
        b.extra_data = b""
write_blocks(out, blocks)
```

Result: 409 → 300 bytes, re-parse with zero warnings, SVG output byte-identical
to the original. The transformation is checked in as
`scripts/clean-stencil.py` for the next time a fresh stencil capture brings
the bytes back.

## What's left

- **UUID statics**: two UUIDs are still baked into every generated bundle (the
  `AuthorIdsBlock` in the stencil, and `cPages.uuids[0].first` in
  `base.content.json`). Same author UUID across every journal we ship.
  Probably fine, but worth randomizing some day.
- **Backfill timestamps**: `./create-daily-note.sh 2026-01-15` stamps
  `createdTime = now()` even though the journal is named for a past day.
  Easy to align if it ever matters.

Everything else lined up. The container is now generating templated, properly
named journals; cleanup is cheap; rmc parses without warnings; and the test
suite covers each fix.
