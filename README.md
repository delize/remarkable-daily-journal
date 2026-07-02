# reMarkable Daily Journal - Docker

Automatically creates dated notebooks on your reMarkable tablet, running as a Docker container.

## Features

- 📅 Creates a new dated notebook every day
- 📝 **Native reMarkable notebooks** using the device's own built-in templates (lined, grid, dots, …) by default — no PDF generation required
- 🎛️ Configurable template per page, including any of the device's ~70 templates, with per-hardware support
- 🖼️ Or bring your own **custom PDF/PNG/JPG background** (`TEMPLATE_PDF`/`TEMPLATE_DOC`) for pages that need more than a built-in template
- 🔄 Runs on a configurable schedule (default: 6:00 AM)
- 🐳 Runs as a lightweight Docker container
- 💾 Persistent authentication (survives container restarts)
- ⏭️ Skips if notebook for that date already exists
- 🕐 Timezone-aware scheduling
- 🧹 Auto-cleanup of unused journals (removes ones that are stale **and** unwritten)
- 🤖 Template list kept up to date automatically from the latest firmware

## Quick Start

### Option A: Use Pre-built Image (Recommended)

```bash
# Pull the latest image
docker pull ghcr.io/delize/remarkable-daily-journal:latest

# Create volume for persistent auth
docker volume create rmapi-config

# Authenticate (one-time)
docker run -it --rm \
  -v rmapi-config:/app/.config/rmapi \
  ghcr.io/delize/remarkable-daily-journal:latest auth

# Run the scheduled service
docker run -d \
  --name remarkable-daily-journal \
  --restart unless-stopped \
  -v rmapi-config:/app/.config/rmapi \
  -e TZ=America/New_York \
  -e CRON_SCHEDULE="0 6 * * *" \
  ghcr.io/delize/remarkable-daily-journal:latest schedule
```

### Option B: Build from Source

```bash
docker compose build
```

Or without compose:
```bash
docker build -t remarkable-daily-journal .
```

### 2. Authenticate with reMarkable Cloud (one-time)

```bash
docker compose run --rm remarkable-daily-journal auth
```

This will:
1. Prompt you to visit https://my.remarkable.com/device/browser/connect
2. Enter the one-time code displayed
3. Save authentication to a persistent Docker volume

### 3. Test the setup

```bash
# Verify authentication works
docker compose run --rm remarkable-daily-journal test

# Create today's note manually
docker compose run --rm remarkable-daily-journal run
```

### 4. Start the scheduled service

```bash
docker compose up -d
```

The container will now run in the background and create a daily journal notebook at 6:00 AM (configurable).

## Configuration

Edit `docker-compose.yml` to customize:

```yaml
environment:
  # Your timezone
  - TZ=Europe/Stockholm

  # When to create notes (cron format)
  # Examples:
  #   0 6 * * *     = 6:00 AM daily
  #   0 5 * * 1-5   = 5:00 AM weekdays only
  #   0 7 * * 0     = 7:00 AM Sundays only
  - CRON_SCHEDULE=0 6 * * *

  # Folder on reMarkable (created automatically)
  - REMARKABLE_FOLDER=/Daily Journal

  # Notebook name format (ISO date recommended for sorting)
  - DATE_FORMAT=%Y-%m-%d

  # Template applied to each page (see "Templates" below).
  # Aliases: blank, lined, grid, checklist — or any raw template name.
  - TEMPLATE_STYLE=lined

  # Device whose template list to validate against: rmpp / rm2 / rm1
  - TEMPLATE_HARDWARE=rmpp

  # Optional: use a custom PDF/PNG/JPG as the page background instead of a
  # built-in template (see "Custom PDF backgrounds" below). Mutually exclusive
  # with TEMPLATE_DOC.
  # - TEMPLATE_PDF=/app/templates/planner.pdf

  # Optional: reuse a PDF-backed document already on your reMarkable cloud as
  # the page background, fetched via rmapi. Mutually exclusive with TEMPLATE_PDF.
  # - TEMPLATE_DOC=/Templates/My PDF Notebook

  # Pages per notebook. 1 is enough — the generator points cPages.lastOpened
  # at page 1, and the device's add-page action copies that page's template.
  - TEMPLATE_PAGES=1

  # Cleanup: remove recent journals that were never written in. Journals older
  # than CLEANUP_KEEP_HOURS are considered settled and never touched.
  - CLEANUP_ENABLED=true

  # Only inspect journals modified within this many hours (cloud ModifiedClient)
  - CLEANUP_KEEP_HOURS=48

  # A page .rm at/below this size (bytes) counts as unwritten
  - EMPTY_RM_MAX_BYTES=1000

  # Skip the download if the cloud bundle is already this big — anything past
  # ~50KB has strokes.
  - EMPTY_BUNDLE_MAX_BYTES=50000

  # Log what cleanup would delete without removing anything
  - CLEANUP_DRY_RUN=false
```

### Author UUID

Every reMarkable page is tagged with an author UUID — the identity that
"wrote" it. Notebooks you create on your tablet inherit your account's UUID;
the journals this container generates default to a **fresh random UUID per
run** so they never leak the same baked identity into the cloud.

If you'd rather have every generated journal tagged as authored by you (so
the device treats them as part of your library), set `AUTHOR_UUID` to your
account's value:

```bash
# pick a notebook you HAND-CREATED on your tablet (not an import, not a
# Methods notebook). The helper rmapi-gets it, reads .cPages.uuids[0].first
# out of its .content, and prints the canonical UUID.
docker exec remarkable-daily-journal \
    /app/scripts/extract-author-uuid.sh "/Quick sheets/Notebook 2"
# -> e.g. c45bf333-c30a-59b0-b588-0b682888b306
```

Then drop the printed value into `docker-compose.yml`:

```yaml
- AUTHOR_UUID=c45bf333-c30a-59b0-b588-0b682888b306
```

and restart the container. From the next run on, every generated journal is
stamped with that UUID in both the page CRDT (`AuthorIdsBlock` in `.rm`) and
the document content (`cPages.uuids[0].first` in `.content`).

There's no official reMarkable documentation about what the cloud or device
actually does with this UUID, so both behaviors (per-run random vs. fixed to
your account) work fine in practice — this is just about which "feels right"
for your library.

### Templates

Journals are **native reMarkable notebooks** that, by default, reference one of
the device's built-in templates by name — the tablet renders the template
itself, so there's no PDF and nothing template-related is uploaded. If you want
a custom background instead, see [Custom PDF backgrounds](#custom-pdf-backgrounds) below.

Set `TEMPLATE_STYLE` to a friendly alias or any raw template name:

| Alias | Template |
|-------|----------|
| `blank` | `Blank` |
| `lined` | `P Lines medium` |
| `grid` | `P Grid medium` |
| `checklist` | `P Checklist` |

```yaml
- TEMPLATE_STYLE=lined        # alias
- TEMPLATE_STYLE=P Dots S     # any raw template name works too
```

The four aliases are just shortcuts for the most common picks — **all ~70
device templates are usable**, including dotted, Cornell, hexagon, music,
margin, planners, storyboards, and more.

**To choose one, browse the mapping** in
[`docs/templates/`](docs/templates/) (e.g. [`rmpp.md`](docs/templates/rmpp.md)
for the Paper Pro). Each entry lists the template's display **Name**, the
**value to put in `TEMPLATE_STYLE`**, and its category — find the one you want
and copy its template value verbatim (spaces and capitalisation matter, e.g.
`P Dots S`, `P Cornell`, `P Hexagon medium`).

An unrecognised name is still used (it just logs a warning), since template sets
differ by device/firmware. Set `TEMPLATE_HARDWARE` (`rmpp`, `rm2`, `rm1`) to
validate against your device's list.

These lists are refreshed automatically from the latest firmware by the
`Update template lists` workflow (every ~2 weeks), which opens a PR when the set
changes.

### Custom PDF backgrounds

> [!NOTE]
> An earlier version of this feature hand-built reMarkable's per-page sync
> structure (`cPages.pages[].redir`) on a document the tablet had never
> opened, and that **crash-looped a real device**. The default behavior
> below was redesigned around that incident and has been verified on real
> hardware (opens cleanly, no crash). See
> [docs/decisions/0001-custom-pdf-page-backgrounds.md](docs/decisions/0001-custom-pdf-page-backgrounds.md)
> and [docs/decisions/0002-redesign-custom-pdf-backgrounds-after-crash.md](docs/decisions/0002-redesign-custom-pdf-backgrounds-after-crash.md)
> for the full incident and redesign. `TEMPLATE_PDF_NATIVE_EXPERIMENTAL`
> (below) is a separate, still-**unverified-on-hardware** opt-in variant —
> leave it off unless you specifically want to help verify it.

Instead of a built-in template, a page can be backed by a real PDF (or a
PNG/JPG, auto-wrapped into a 1-page PDF) — e.g. a downloaded planner or
template pack.

Two mutually-exclusive sources:

```yaml
# A file mounted into the container (see the /app/templates volume below)
- TEMPLATE_PDF=/app/templates/planner.pdf

# ...or a PDF-backed document already on your reMarkable cloud, fetched via rmapi
- TEMPLATE_DOC=/Templates/My PDF Notebook
```

`TEMPLATE_PDF` also accepts a `.png`/`.jpg`/`.jpeg` image directly — it's
wrapped into a 1-page PDF automatically (via `img2pdf`) before continuing.

**Default behavior (safe, verified)**: the resolved PDF is uploaded as a
**plain PDF document** — no notebook bundle, no hand-built page structure at
all. This is deliberately identical in spirit to `rmapi put somefile.pdf`,
the same path any normal PDF import already uses safely: the tablet itself
builds its own page structure the first time you open it. Because of this,
`TEMPLATE_STYLE` doesn't apply once `TEMPLATE_PDF`/`TEMPLATE_DOC` is set — the
source's own pages are what you get.

Note: on a PDF-backed document, the tablet's own "add page" feature inserts a
genuinely blank page (no template, no background) rather than repeating your
custom page — PDF pages are literal embedded content, not a template
reference the device can copy forward. This is standard reMarkable behavior
for any PDF import, not specific to this tool.

**Repeating a page across a multi-page daily note**: if you explicitly set
`TEMPLATE_PAGES` higher than the source's own page count, the source's pages
are repeated (cycling through them in order) at the *file level* — via
`qpdf`, before upload — to reach that count. This is a plain PDF-page
duplication, not device-side page invention, so it stays within the same
proven-safe upload path. Leave `TEMPLATE_PAGES` unset (or ≤ the source's own
page count) to upload the source completely unchanged.

```yaml
# A 1-page source, repeated to a 5-page document
- TEMPLATE_PDF=/app/templates/cover.pdf
- TEMPLATE_PAGES=5
```

**`TEMPLATE_PDF_NATIVE_EXPERIMENTAL=true`** (opt-in, off by default) instead
builds a native `.rmdoc` bundle ourselves — keeping `AUTHOR_UUID` stamping and
`CREATED_TIME_MS` historical-date backfill working — but leaves `cPages`
entirely at its pristine, empty "never opened" default rather than
pre-populating any page entries. This is a lower-risk hypothesis than what
crashed (no CRDT page array is invented at all), but has **not been
independently verified on real hardware** — treat it as experimental.

To mount a local file, add a volume and point `TEMPLATE_PDF` at a path inside it:

```yaml
volumes:
  - ./templates:/app/templates:ro
environment:
  - TEMPLATE_PDF=/app/templates/planner.pdf
```

Setting both `TEMPLATE_PDF` and `TEMPLATE_DOC` is an error. Neither set →
today's built-in-template-only behavior, unchanged.

**Not supported, deliberately**: `methods.remarkable.com` (reMarkable's own
template marketplace) isn't integrated — its "Import" button is an
authenticated first-party push straight into your reMarkable account, with no
PDF file ever exposed to fetch programmatically; download from there yourself
and use it as a `TEMPLATE_PDF`/`TEMPLATE_DOC` source like any other PDF. This
also doesn't install a template into the device's own template picker for
other documents (that requires SSH access to the device and is out of scope
here) — it only affects the journal this tool generates.

#### Different reMarkable models / screen sizes

The blank-page stencil (`assets/blank-page.rm`) and base `.content`
(`assets/base.content.json`) were captured from a **reMarkable Paper Pro**, and
generation is **verified on the Paper Pro**. Two things are worth separating:

- **Document geometry** — the `.rm`/`.content` use reMarkable's canonical
  document canvas (1404 × 1872). Notably, the Paper Pro's *own* notebooks use
  this same canvas despite its larger, color screen — evidence that the
  stroke/page coordinate space is **device-independent**, so one stencil +
  `.content` very likely works across models. (`.metadata` is just document
  metadata — no geometry.)
- **Template rendering** — reMarkable ships **device-specific** template assets
  rather than scaling one design to every screen
  ([source](https://spacepanda.se/articles/rm_methods.html)). But we never ship
  a template; we reference it by *name* and the device draws its own asset. So
  the only per-device variable is which template **names** exist — covered by
  `TEMPLATE_HARDWARE` and the lists in `docs/templates/`.

Net: per-device `.rm`/`.content` are most likely **unnecessary**; only
template-name availability differs. This is inferred from the Paper Pro using
the canonical canvas and is **not yet tested on a physical reMarkable 1/2** — if
a journal mis-renders there, capturing that device's blank stencil would be the
fix.

### Cleanup Behavior

Native notebooks always contain a `.rm` layer per page, so "has a `.rm` file"
no longer means "written in". The cleanup pass only ever touches **recent,
auto-generated, never-written-in** journals; anything older than the window is
left alone forever:

1. List all journals in the reMarkable folder
2. Skip today's journal
3. **Skip any journal older than `CLEANUP_KEEP_HOURS`** (using the cloud's
   `ModifiedClient` time). Once a journal is past the window it is considered
   settled — never downloaded, never deleted.
4. For in-window journals, try cheap short-circuits before downloading:
   - **Cache**: a persistent `{name → ModifiedClient}` cache (at
     `CLEANUP_CACHE`, defaulting to `/app/.config/rmapi/cleanup-cache.tsv`)
     records every journal we've already verified as written-on. If the cache
     hit's `ModifiedClient` matches today's, skip the download.
   - **Cloud size**: if `rmapi stat`'s `sizeInBytes` is above
     `EMPTY_BUNDLE_MAX_BYTES` (default 50000), treat as written-on and skip.
5. Only journals that survived the short-circuits get downloaded. Check the
   largest page `.rm`:
   - an unwritten page is just the empty scene skeleton (~409 bytes)
   - writing on a page makes its `.rm` grow (typically 2600+ bytes)
6. If every page is at/below `EMPTY_RM_MAX_BYTES`, the journal is empty → deleted;
   otherwise it has writing → cached and kept.

To preview without deleting, set `CLEANUP_DRY_RUN=true` for one run and watch the
log. To disable cleanup entirely:
```yaml
- CLEANUP_ENABLED=false
```

To widen the deletion window (e.g., 7 days — anything still empty after a week
gets cleaned up):
```yaml
- CLEANUP_KEEP_HOURS=168
```

## Authentication Storage

The rmapi authentication token must persist between container restarts. Two options:

### Option A: Docker Named Volume (Default)

```yaml
volumes:
  - rmapi-config:/app/.config/rmapi
```

- Managed by Docker
- Survives container rebuilds
- View with: `docker volume inspect rmapi-config`

### Option B: Bind Mount to Local Directory

```yaml
volumes:
  - ./config/rmapi:/app/.config/rmapi
  # Or absolute path:
  - /home/user/.config/rmapi:/app/.config/rmapi
```

- You control the location
- Easy to backup/migrate
- Create the directory first: `mkdir -p ./config/rmapi`

When using bind mount, comment out the `volumes:` section at the bottom of docker-compose.yml.

## Commands

| Command | Description |
|---------|-------------|
| `auth` | Interactive authentication with reMarkable Cloud |
| `run` | Create today's journal note immediately |
| `schedule` | Run as daemon, creating notes on schedule (default) |
| `test` | Verify authentication and configuration |
| `shell` | Drop into bash shell for debugging |

### Examples

```bash
# One-shot: create today's note
docker compose run --rm remarkable-daily-journal run

# Create note for a specific date
docker compose run --rm remarkable-daily-journal run "2025-02-15"

# Check logs
docker compose logs -f

# Stop the service
docker compose down

# Re-authenticate (if token expires)
docker compose run --rm remarkable-daily-journal auth
```

## Running Without Docker Compose

```bash
# Create volume for persistent auth
docker volume create rmapi-config

# Authenticate
docker run -it --rm \
  -v rmapi-config:/app/.config/rmapi \
  remarkable-daily-journal auth

# Run scheduled
docker run -d \
  --name remarkable-daily-journal \
  --restart unless-stopped \
  -v rmapi-config:/app/.config/rmapi \
  -e TZ=Europe/Stockholm \
  -e CRON_SCHEDULE="0 6 * * *" \
  -e REMARKABLE_FOLDER="/Daily Journal" \
  remarkable-daily-journal schedule
```

## Integration with Your Homelab

### Traefik (no web interface, but for completeness)

This container doesn't expose any ports, so no Traefik config needed.

### Portainer

Import the `docker-compose.yml` as a stack in Portainer.

### Running on Synology/QNAP NAS

1. Build the image on your NAS or push to a registry
2. Use the NAS Docker GUI to create the container
3. Map the `/app/.config/rmapi` volume to a persistent location
4. Set environment variables as needed

## Notebook Naming

By default each notebook is named by `DATE_FORMAT` (ISO date), e.g. `2026-05-31`.

To customise the name — append or prepend text — set `JOURNAL_NAME_FORMAT`, a
strftime format that **defaults to `DATE_FORMAT`**:

```yaml
- JOURNAL_NAME_FORMAT=Journal %Y-%m-%d     # -> "Journal 2026-05-31"
- JOURNAL_NAME_FORMAT=%Y-%m-%d - Work      # -> "2026-05-31 - Work"
- JOURNAL_NAME_FORMAT=%A %Y-%m-%d          # -> "Sunday 2026-05-31"
```

The **folder** is set separately with `REMARKABLE_FOLDER` (default `/Daily Journal`).

Keep the date first to sort chronologically, and keep an ISO date (`%Y-%m-%d`)
somewhere in the name — the cleanup job finds journals by matching `YYYY-MM-DD`.

## Troubleshooting

### "rmapi not authenticated"

Re-run authentication:
```bash
docker compose run --rm remarkable-daily-journal auth
```

### Notebooks not appearing on reMarkable

1. Check container logs: `docker compose logs`
2. Ensure your reMarkable is connected to WiFi and syncing
3. Pull down to refresh on the tablet
4. Check the correct folder on reMarkable

### Wrong timezone

Update `TZ` in docker-compose.yml:
```yaml
- TZ=America/New_York  # or your timezone
```

Find your timezone: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones

### Authentication expires

reMarkable tokens can expire. Re-authenticate:
```bash
docker compose run --rm remarkable-daily-journal auth
```

### Debug mode

```bash
# Drop into shell
docker compose run --rm remarkable-daily-journal shell

# Inside container, test manually
/app/create-daily-note.sh

# Check rmapi directly
rmapi ls /
rmapi ls "/Daily Journal"
```

## File Structure

```
.
├── .github/
│   └── workflows/
│       ├── ci.yml                  # Lint, test, build & push image
│       └── update-templates.yml    # Biweekly template-list refresh from firmware
├── assets/
│   ├── blank-page.rm               # Blank v6 page stencil cloned per page
│   ├── base.content.json           # Known-good .content template
│   └── templates/
│       └── rmpp.json               # Canonical template list (per hardware)
├── docs/
│   └── templates/
│       └── rmpp.md                 # Human-readable template reference (generated)
├── scripts/
│   ├── generate-template-docs.sh   # Render docs/templates/<hw>.md from the JSON
│   └── update-templates.sh         # Refresh a hardware's list from latest firmware
├── tests/                          # Bats tests (one per script) + run-tests.sh
├── Dockerfile                      # Multi-stage build with rmapi
├── docker-compose.yml              # Service definition
├── create-daily-note.sh            # Builds + uploads the daily journal
├── generate-native-journal.sh      # Builds the native .rmdoc bundle
├── cleanup-old-journals.sh         # Removes stale, unwritten journals
├── entrypoint.sh                   # Container entrypoint
└── README.md                       # This file
```

## Development

### Running Tests Locally

```bash
# Install dependencies (macOS)
brew install shellcheck bats-core

# Install dependencies (Ubuntu/Debian)
sudo apt-get install shellcheck bats

# Run all tests
./tests/run-tests.sh

# Run specific test types
./tests/run-tests.sh lint     # Shellcheck only
./tests/run-tests.sh unit     # Bats unit tests only
./tests/run-tests.sh syntax   # Bash syntax check only
```

### CI/CD Pipeline

The GitHub Actions workflow (`ci.yml`) runs automatically on push/PR:

```
Stage 1: Lint          → Shellcheck + Bash syntax validation
    ↓
Stage 2: Unit Tests    → Bats test suite
    ↓
Stage 3: Docker Build  → Build image + integration tests (dry run)
    ↓
Stage 4: Push          → Build (amd64) → GHCR (latest + version tags)
```

Push stage only runs on `main` branch and version tags, not on PRs.

A second workflow (`update-templates.yml`) runs on a schedule (~every two weeks)
to refresh the per-hardware template lists from the latest firmware and open a
PR when they change. It can also be triggered manually from the Actions tab.

## How It Works

1. **Build stage**: Compiles `rmapi` from the [ddvk/rmapi](https://github.com/ddvk/rmapi) fork (actively maintained)
2. **Runtime**: Alpine Linux. Each journal is assembled as a native reMarkable `.rmdoc` bundle — a fresh document UUID, pages cloning a blank v6 `.rm` stencil, with the chosen built-in template referenced in `.content` — then uploaded with `rmapi`. The device renders the template, so no PDF/Ghostscript rendering is involved. Optionally, a page can instead redirect to a page of a user-supplied PDF (`TEMPLATE_PDF`/`TEMPLATE_DOC`, see [Custom PDF backgrounds](#custom-pdf-backgrounds)) — the PDF is embedded as-is, never rendered by us.
3. **Scheduling**: Uses a lightweight shell-based scheduler (no root required)
4. **Auth storage**: Persisted in Docker volume, survives container updates

## Contributing

Feel free to open issues or PRs for:
- Multiple folder support
- Weekly/monthly notebook options
- Per-page mixed templates
- Integration with other note systems
