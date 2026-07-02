---
type: decision
id: 0001
status: accepted
date: 2026-07-01
domain: architecture
context: home
systems: [remarkable-daily-journal, rmapi]
source_repo: github.com/delize/remarkable-daily-journal
---

# Custom PDF page backgrounds for the daily journal

## Context

The daily journal currently generates native reMarkable notebooks whose pages
only ever reference a *built-in device template* by name (e.g. `"P Lines
medium"`) — this was a deliberate simplification (commit `2613b57`) after
removing an earlier Ghostscript-based PDF-generation pipeline.

The goal: bring back the ability to use a **real, user-supplied PDF** as a
page's visual background — e.g. a downloaded planner/template pack (like
https://github.com/deo-so/reMarkable-Tablet-Templates---Free) — either from a
file mounted into the container, or from a document already sitting on the
reMarkable cloud/tablet.

## Options considered

1. **Integrate with `methods.remarkable.com`** (reMarkable's own template
   marketplace) — investigated live against the user's authenticated session.
   Its "Import" button authenticates via Auth0 straight into reMarkable's own
   cloud API (`audience=https://web.cloud.remarkable.com`) and pushes content
   directly into the device's own template picker — there is no PDF file ever
   exposed to a browser/scraper. Even reverse-engineering that internal API
   would only cover content already hosted on that one paywalled site, which
   doesn't serve the actual use case (arbitrary PDFs like the deo-so repo).
   **Rejected** — doesn't serve the use case, and the officially-supported
   path (clicking Import yourself) already exists for that site's own content.
2. **On-device template-registry (SSH) installation** — convert the PDF into
   a template asset and register it in `/usr/share/remarkable/templates` +
   `templates.json` on-device, making it a selectable template for *any*
   document. **Rejected** — requires SSH/root device access, is unofficial
   and firmware-fragile, and is broader in scope than needed (this feature
   only needs to affect the journal this tool generates, not the device's
   global template list).
3. **Embed the PDF directly in the generated `.rmdoc`, using reMarkable's own
   PDF-backed-document mechanism** — chosen. Verified against a genuine
   device-produced fixture (see below) that reMarkable's real `.content`
   schema already supports mixing PDF-page references and built-in-template
   references page-by-page within the same document.

## Decision

Add two new, mutually-exclusive env vars to `generate-native-journal.sh` /
`create-daily-note.sh` (both already covered by `entrypoint.sh`'s
`export_env()` `TEMPLATE_` prefix whitelist — no change needed there):

- **`TEMPLATE_PDF=<path>`** — a PDF file mounted into the container from the
  host, via a new `/app/templates` read-only volume (mirrors the existing
  `/app/.config/rmapi` volume convention).
- **`TEMPLATE_DOC=<cloud path>`** — a document already on the user's
  reMarkable cloud/tablet, fetched with `rmapi get "<path>"` (same pattern
  `cleanup-old-journals.sh` and `scripts/extract-author-uuid.sh` already use),
  unzipped, with its embedded `<uuid>.pdf` located and reused. Errors clearly
  if the fetched document has no embedded PDF (it's a plain notebook, not a
  PDF-backed one).

Setting both is a hard error. Neither set → completely unchanged behavior
(today's notebook-only path).

**Ground truth used to design the schema** (pulled from a genuine
device-produced PDF-backed `.content` fixture at
`rmrkle-sparkle/tests/fixtures/real_v6/getting-started/25999b23-...content`,
with its sibling real `.pdf`): `fileType: "pdf"`, `pageCount: 9`,
`coverPageNumber: 0`, `sizeInBytes: "741100"` (string). `cPages.pages[]` mixes
one page with `redir: {value: 0}` (0-based index into the source PDF) and
eight pages with `template: {value: "Blank"}` — i.e. redirection and
built-in-template references legitimately coexist page-by-page in the same
document. The `redir` page has no `.rm` file in the bundle at all (lazily
created only on first annotation); every `template` page does have one.

Note: `rmapi put`'s own client-side path for a raw PDF upload does *not*
pre-build `cPages`/`redir` — it uploads the bare PDF with an empty page
structure and lets the tablet itself lazily allocate `cPages`/`redir`/`.rm`
on first open. This decision pre-builds the full `cPages` ourselves
(mirroring what a *synced* device eventually produces), which goes further
than rmapi's own raw-PDF path — flagged for manual on-device verification
since it's inferred from a single fixture, not documented anywhere official.

**Page mapping**: for page `i` in `1..TEMPLATE_PAGES`, if `i <= PDF_PAGE_COUNT`
→ `redir: {value: i-1}` (no stencil clone, no `.rm` file). Otherwise → today's
`template`-based branch, unchanged. No page-cycling in this iteration (a PDF
with fewer pages than `TEMPLATE_PAGES` gets its extra pages filled by the
existing template mechanism, not a repeat of PDF page 0) — matches the one
real-world example available; documented as possible future work.

`PDF_PAGE_COUNT` is computed with `qpdf --show-npages` (new Dockerfile
dependency — small, Alpine main-repo package). `sizeInBytes` is computed
fresh from the real embedded PDF's byte size. `coverPageNumber` becomes `0`
whenever any PDF is embedded, else stays `-1`.

Full file-by-file implementation plan (exact line numbers, test plan,
Dockerfile/docker-compose/README changes, verification steps) is captured in
this repo's working session; see `generate-native-journal.sh`,
`Dockerfile`, `docker-compose.yml`, `tests/generate-native-journal.bats`, and
`README.md` for the eventual implementation.

## Consequences

- New runtime dependency: `qpdf` in the Docker image.
- New volume: `/app/templates` (read-only bind mount) for `TEMPLATE_PDF`.
- `generate-native-journal.sh` gains a PDF-sourcing/validation branch but the
  no-PDF (default) code path stays byte-for-byte unchanged — pinned by
  existing "never null" invariant tests.
- One behavior (pre-building `cPages.redir` for a never-before-opened
  document) is unverified against real device firmware and must be confirmed
  manually before this is considered fully proven, not just implemented.
- `EMPTY_BUNDLE_MAX_BYTES` cleanup heuristic may now treat an unannotated
  PDF-backed journal as "written-on" purely because the embedded PDF pushes
  bundle size over the threshold — a pre-existing heuristic limitation with a
  new trigger, not addressed by this decision.
- `methods.remarkable.com` and on-device SSH template registration remain
  explicitly out of scope; should either resurface as a request, this ADR
  documents why they were rejected rather than re-investigating from scratch.
