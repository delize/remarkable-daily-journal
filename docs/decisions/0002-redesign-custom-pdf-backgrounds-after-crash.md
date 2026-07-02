---
type: decision
id: 0002
status: accepted
date: 2026-07-02
domain: architecture
context: home
systems: [remarkable-daily-journal, rmapi]
supersedes: [[0001-custom-pdf-page-backgrounds]]
source_repo: github.com/delize/remarkable-daily-journal
---

# Redesign custom PDF page backgrounds after a real-device crash-loop incident

## Context

ADR 0001 designed `TEMPLATE_PDF`/`TEMPLATE_DOC` by hand-building reMarkable's
`cPages.pages[]` CRDT array (mixing `redir` and `template` entries) on a
freshly generated `.rmdoc`, grounded in a real device-produced fixture.
Implemented and tested extensively (28+ Bats tests, a real Docker build,
Trivy CVE scan, full container smoke tests) — then verified on a real
reMarkable tablet by uploading a test document via an authenticated `rmapi`.

The tablet immediately entered a **repeated restart/crash loop** upon opening
it. Deleting the document from the cloud (`rmapi rm`, soft delete to trash)
stopped the loop as soon as the device no longer had it to sync.

## Root cause

Identified from first principles — re-reading `rmapi`'s own Go source
(already reviewed earlier in the same session for an unrelated reason), not
from any external bug report (a background research pass across GitHub
issues, community reports, and reverse-engineered schema docs found no exact
match for this failure mode).

`rmapi`'s own `put` command for a raw PDF upload — the path millions of
`rmapi` users rely on safely every day — ships with **no pre-built
`cPages`/`redir`/page-UUIDs at all** (`pageIds` stays `nil`). The tablet's
own firmware lazily constructs `cPages`, per-page UUIDs, and `redir`
mappings the first time a human actually opens the document. ADR 0001's
design instead pre-built a fully-formed `cPages` array mixing `redir` and
`template` entries **on a document the tablet had never opened before** —
inventing CRDT/sync state that's supposed to only ever be constructed by the
device itself. That's exactly the risk ADR 0001 flagged as unverified, and
it's what crashed real hardware.

## Options considered

1. **Keep investigating before touching real devices again** — try to
   isolate which specific field caused the crash by testing intermediate
   variants. Rejected: the root cause (inventing CRDT state pre-sync) was
   already clear from `rmapi`'s own source; further isolation wouldn't
   change the fix, just delay it.
2. **Match `rmapi`'s proven-safe raw-PDF upload exactly** — chosen as the
   default. Drop all hand-built `cPages`/`redir` construction entirely.
3. **Still offer a native `.rmdoc` variant, minus only the crash-causing
   part** — chosen as an additional, clearly-labeled opt-in, once it became
   clear the crash was specifically about pre-built CRDT *page* state, not
   about scalar document properties.

## Decision

Redesigned `generate-native-journal.sh` into two modes:

1. **Default (safe, verified on real hardware)**: `TEMPLATE_PDF`/`TEMPLATE_DOC`
   resolves to a plain `.pdf` file — no notebook bundle, no `cPages` at all —
   uploaded via `rmapi put` exactly the way any ordinary PDF import already
   works. `TEMPLATE_PAGES`/`TEMPLATE_STYLE` no longer apply once a PDF
   source is set: you get the source PDF's own pages, and the tablet decides
   the resulting page structure. **Verified**: uploaded a real test document
   to the user's tablet; it opened cleanly with no crash-loop.
2. **`TEMPLATE_PDF_NATIVE_EXPERIMENTAL=true`** (opt-in, off by default, **not
   yet verified on hardware**): builds a native `.rmdoc` ourselves — keeping
   `AUTHOR_UUID` stamping and `CREATED_TIME_MS` historical-date backfill
   working — but leaves `cPages` entirely at its pristine, empty "never
   opened" default (`cPages.pages: []`, `lastOpened` untouched) rather than
   pre-populating any page array. Only scalar document properties
   (`fileType`, `pageCount`, `sizeInBytes`, `cPages.uuids[0]` for author
   identity) are touched — never per-page CRDT state. Lower risk than what
   crashed, but still a hypothesis pending its own dedicated real-device
   test before it can be trusted.

Also documented (not a bug, observed during verification): on a PDF-backed
document, the tablet's "add page" feature inserts a **blank** page rather
than copying the custom background forward. PDF pages are literal embedded
content, not a template reference the way the notebook path's
`cPages.lastOpened` mechanism works — this is standard reMarkable behavior
for any PDF import, not specific to this tool.

## Consequences

- Lost capability (accepted trade-off): a PDF-backed page can no longer be
  mixed with extra built-in-template pages in the same document, and
  `TEMPLATE_PAGES` doesn't control a PDF-backed document's page count. That
  mixing was the crash-implicated part.
- `qpdf` is no longer a hard dependency — nothing in either mode needs the
  source PDF's page count for correctness anymore (only used opportunistically,
  optionally, for a cosmetic page-count value in the experimental variant).
- The README carries a clear notice distinguishing the verified-safe default
  from the still-unverified experimental variant; the experimental variant
  must not be assumed safe just because the default path was fixed.
- The crashing bundle and a repro writeup were preserved and handed to the
  user for a potential reMarkable bug report (tracked outside this ADR).
