# From Ghostscript PDFs to native reMarkable templates

*2026-05-31*

For its first 1.x.x lifetime, `remarkable-daily-journal` worked the obvious
way: every morning at 06:00, the container shelled out to Ghostscript, drew a
lined or grid background into a PDF, and pushed the PDF to the reMarkable
cloud via `rmapi`. It worked, but the seams showed — the journals looked like
PDFs (because they were), pages were "annotation on top of a flat document"
rather than real notebook pages, and the container carried a full Ghostscript
install just to draw horizontal lines.

This is the story of replacing all of that with a 6 KB native notebook bundle
that the device renders itself, and the year of small detours it took to get
there. PRs: [#1 native-templates][pr1], [#2 template-registry][pr2], and the
[v2.0.0][v2] / [v2.1.0][v21] / [v2.2.0][v22] releases.

[pr1]: https://github.com/delize/remarkable-daily-journal/pull/1
[pr2]: https://github.com/delize/remarkable-daily-journal/pull/2
[v2]: https://github.com/delize/remarkable-daily-journal/releases/tag/v2.0.0
[v21]: https://github.com/delize/remarkable-daily-journal/releases/tag/v2.1.0
[v22]: https://github.com/delize/remarkable-daily-journal/releases/tag/v2.2.0

## What v1 was doing

The v1 daily run looked something like this (simplified from
`create-daily-note.sh` before the rewrite):

```
[06:00:00] Schedule matched! Running daily journal tasks...
[06:00:17] Creating daily journal: 2026-05-27
[06:00:17] Target folder: /Daily Journal
[06:00:17] Generating 5 page lined PDF...
[06:00:17] PDF created: /tmp/tmp.CdIdGp/2026-05-27.pdf
[06:00:17] Uploading to reMarkable...
uploading: [/tmp/tmp.CdIdGp/2026-05-27.pdf]...OK
[06:00:19] ✓ Daily journal created successfully: 2026-05-27
```

Pipeline: Ghostscript draws → PDF on disk → `rmapi put` → cloud → tablet.
A typical 5-page lined PDF was 20–50 KB. Annotated journals from the past
few months had grown to 200–600 KB each. The cleanup pass had to download
every old journal just to peek at whether any annotation layer existed.

It worked. It just wasn't… right.

## The question that started the rewrite

> "Is there a way to utilize the templates from reMarkable in the daily
> journal, based on the content from
> [Scrybbling-together/remarks#68](https://github.com/Scrybbling-together/remarks/pull/68)?
> Is it possible to add templating from reMarkable into the daily journal?
> That way we don't have to generate a PDF ourselves, and can use the
> templates for this?"

The PR being referenced was about *exporting* template-aware notebooks. The
interesting bit for us was the inverse: **built-in templates already live on
every device** (`/usr/share/remarkable/templates/`), and a native notebook
doesn't embed the template image — each page in the notebook's `.content`
metadata just **references a template by name**. The device renders the
background itself.

So in principle: stop generating PDFs, ship a tiny `.rmdoc` bundle whose pages
say `"template": "P Lines medium"`, and let the tablet draw the lines.

Three things had to be true for that to be viable, and only one of them was
obvious:

1. `rmapi put` had to accept native `.rmdoc` bundles (not just PDF/epub).
2. We had to know the exact built-in template name strings for the target
   firmware.
3. We had to be able to assemble a valid `.rmdoc` from scratch, including a
   v6 `.rm` page-data file (which is binary CRDT-structured and not
   trivially hand-rollable).

## Detour #1: drawj2d (and why we abandoned it)

The first plan was to use [drawj2d][drawj2d], a Java tool that produces
`.rmdoc` notebooks with native pages. That solved problem #3 — drawj2d emits
valid `.rm` files. But once we read the docs carefully, drawj2d had **no
documented way to assign a template** to a page; you'd still have to crack
open the bundle and patch the `.content` JSON yourself. And it pulled in a
JVM as a runtime dependency in a container that otherwise only needed bash +
`jq` + `zip`.

We kept it as a fallback and went looking for something cheaper.

[drawj2d]: https://drawj2d.sourceforge.io/

## The cheaper path: round-trip a real notebook

The container already had an authenticated `rmapi`. A notebook created on the
tablet *is* a valid native `.rmdoc`. So before solving any of the harder
problems, we tested problem #1 the cheap way:

```bash
# Create "TemplateProbe" on the tablet, sync, then:
docker exec -w /tmp remarkable-daily-journal rmapi get "/TemplateProbe"
docker cp remarkable-daily-journal:/tmp/TemplateProbe.rmdoc ./probe.rmdoc

# Rename UUIDs, change visibleName, re-zip:
unzip probe.rmdoc -d probe/
OLD=$(basename probe/*.content .content)
NEW=$(uuidgen | tr 'A-Z' 'a-z')
( cd probe && for f in *; do mv "$f" "${f//$OLD/$NEW}"; done )
sed -i 's/"TemplateProbe"/"TemplateProbe2"/' probe/*.metadata
( cd probe && zip -r ../probe2.rmdoc * )

docker exec -w /tmp remarkable-daily-journal rmapi put /tmp/probe2.rmdoc /rmdoc-test
```

Result: it synced cleanly, opened on the device as a normal templated
notebook. **`rmapi put` handles native bundles.** Question #1 — the only
one that could have killed the whole approach — was answered without writing
a line of generator code.

## Discovering the template names without SSH

Question #2 was harder than it looked. The "right" way to enumerate templates
is to SSH to the tablet and read `/usr/share/remarkable/templates/templates.json`.
But the Paper Pro we were targeting was on a fresh account with no developer
mode (`scp root@10.11.99.1:…` → `Connection reset by peer`).

The workaround surfaced by accident: the device exposes its built-in templates
as notebooks in a `/Templates` folder, visible via plain `rmapi ls`:

```
$ docker exec remarkable-daily-journal rmapi ls /Templates
[f]    Blank
[f]    Checklist
[f]    Grid Medium
[f]    Lined Medium
```

Each of those is a one-page notebook whose `.content` references the template
by its *exact* internal name. Pull them down, peek inside, and you get the
strings:

```
$ docker exec -w /tmp remarkable-daily-journal sh -c '
    for n in Blank Checklist "Grid Medium" "Lined Medium"; do
      rmapi get "/Templates/$n" >/dev/null 2>&1
      printf "%-14s -> " "$n"
      unzip -p "$n.rmdoc" "*.content" | grep -A2 template | grep value
    done'
Blank          ->     "value": "Blank"
Checklist      ->     "value": "P Checklist"
Grid Medium    ->     "value": "P Grid medium"
Lined Medium   ->     "value": "P Lines medium"
```

That's where the `P ` (portrait) prefix and lowercase `medium` came from —
firmware-internal naming convention we'd never have guessed.

The same trick works on any device the user has cloud-synced. No SSH, no
developer mode, no warranty void.

## Assembling the bundle from scratch

With `rmapi put` confirmed and the template strings in hand, the generator
shrank to bash + `jq` + `zip`. The shape of an `.rmdoc` is:

```
<docid>.content    # JSON: page list + per-page template reference
<docid>.metadata   # JSON: visibleName, createdTime, type, parent, ...
<docid>/
  <pageid>.rm      # binary v6 CRDT page-data, one per page
```

Two of those three we could write trivially. The `.rm` files were the
sticking point — the v6 format isn't something you hand-roll. The way around
it: ship a single 409-byte v6 stencil for a blank page (extracted from a
device notebook, included as `assets/blank-page.rm`) and clone it for each
page. The device only needs the stencil to be structurally valid; the
template comes from the per-page `template.value` string in `.content`,
which the device looks up against its own firmware-shipped templates.

The result is `generate-native-journal.sh`: ~120 lines of bash that produces
a fully native bundle in a few hundred milliseconds, with no Ghostscript, no
JVM, no PDF.

## What the cleanup had to learn

Switching to native bundles broke one of v1's assumptions about cleanup.
The old detector treated "the bundle contains a `.rm` file" as "the user
wrote on this notebook." That made sense when PDFs had no `.rm` until you
annotated them. With native bundles, **every page ships with a `.rm`** — the
empty scene skeleton, ~400 bytes. So we had to switch to a size-based check:

```bash
max_rm=$(unzip -l "$bundle" | awk '$NF ~ /\.rm$/ {print $1}' | sort -n | tail -1)
# An unwritten page's .rm is the empty scene (~409 B).
# Any real ink pushes it well past 1000 B.
[ "$max_rm" -gt "$EMPTY_RM_MAX_BYTES" ] && keep || delete
```

This is the same check `cleanup-old-journals.sh` runs today.

## v2.1: per-hardware template registry

The four templates we'd discovered via `/Templates` were the *named-quick-pick*
subset. The real list is ~70 templates per device, and the set differs
across `rm1` / `rm2` / `rmpp` / `rmppm`. Once we had the v2.0 plumbing
working, [PR #2][pr2] added a real registry:

- Per-hardware JSON lists under `assets/templates/<hw>.json`, derived from
  the firmware's own `templates.json`.
- `TEMPLATE_HARDWARE` env var selects which list to validate against.
- A GitHub Actions workflow (`update-templates.yml`) runs biweekly,
  re-extracts the lists from the latest firmware image using
  [`codexctl`](https://github.com/Eeems-Org/codexctl), and opens a PR when
  the set changes.

The biweekly refresh means the registry stays current without anyone needing
to babysit it. The Paper Pro list, for example, came straight out of
`codexctl cat .../templates/templates.json` against the rmpp 3.27.1 image.

## v2.2: cosmetic + flexibility

`v2.2.0` added what experience said was missing:

- `JOURNAL_NAME_FORMAT` — strftime override so the visible name can be
  `Journal 2026-05-31` or `2026-05-31 - Work` instead of just the date.
- Multi-hardware template references for `rm1` / `rm2` / `rmpp` / `rmppm`,
  with per-device docs under `docs/templates/`.

(`v2.2.0` also unblocked the README rewrite — [PR #3][pr3] — which is when
the user-facing docs finally caught up to where the code had been since
2026-05-31.)

[pr3]: https://github.com/delize/remarkable-daily-journal/pull/3

## What we measured

The PDF era vs native era, container-side:

| | v1 (PDF) | v2 (native) |
|---|---|---|
| Container deps | Ghostscript, PDF tooling | bash, `jq`, `zip` |
| Generated 5-page bundle | ~20 KB | ~6 KB |
| Per-page render | flat PDF lines | device-native template |
| Add-page on device | new blank PDF page (no template) | new native page (templated)\* |
| Editable as a notebook | no — annotation layer | yes |
| Cleanup signal | `.rm` exists | largest `.rm` > threshold |

\* The "add-page inherits template" property turned out to need one more
fix in [PR #5][pr5] — it depends on `cPages.lastOpened.value` pointing at
a real page, which v2.0 wasn't doing. That's covered in the
[follow-up post](2026-06-01-fixing-the-daily-journal.md).

[pr5]: https://github.com/delize/remarkable-daily-journal/pull/5

## Lessons that generalized

Three things from this migration are worth remembering for the next time
something looks like it needs a heavy dependency:

1. **Round-trip beats reverse-engineer.** We could've spent days reading the
   `.rmdoc` spec; instead, we proved the format was supported by
   round-tripping a real device-created notebook in 30 seconds. The same
   trick works for any opaque container format you suspect is "just a zip
   of known files."
2. **The device often re-exports its internals as user-visible data.**
   We needed `/usr/share/remarkable/templates/templates.json` and had no
   SSH. The device kindly exposed the same information as a `/Templates`
   folder over the cloud API. Worth checking before reaching for hardware
   access.
3. **Replace expensive locals with cheap remote references.** v1 rendered
   the template in our container; v2 ships a 6-byte string saying "use
   the one you already have." Same end result, ~30× smaller bundle, and
   the device owns the rendering quality.

The native-template approach also opened up the rest of the work that
followed — per-hardware lists, the biweekly auto-refresh, the cleanup
heuristics — none of which were possible while the journal was a flat PDF.
