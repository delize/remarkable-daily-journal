# reMarkable Daily Journal - Docker

Automatically creates dated notebooks on your reMarkable tablet, running as a Docker container.

## Features

- 📅 Creates a new dated notebook every day
- 📝 **Native reMarkable notebooks** using the device's own built-in templates (lined, grid, dots, …) — no PDF generation
- 🎛️ Configurable template per page, including any of the device's ~70 templates, with per-hardware support
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

  # Pages per notebook. 1 is enough — the generator points cPages.lastOpened
  # at page 1, and the device's add-page action copies that page's template.
  - TEMPLATE_PAGES=1

  # Cleanup: remove old journals that were never written in
  - CLEANUP_ENABLED=true

  # Keep journals modified within this many hours (cloud ModifiedClient time)
  - CLEANUP_KEEP_HOURS=48

  # A page .rm at/below this size (bytes) counts as unwritten
  - EMPTY_RM_MAX_BYTES=1000

  # Log what cleanup would delete without removing anything
  - CLEANUP_DRY_RUN=false
```

### Templates

Journals are **native reMarkable notebooks** that reference one of the device's
built-in templates by name — the tablet renders the template itself, so there's
no PDF and nothing template-related is uploaded.

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
no longer means "written in". Instead, a journal is removed only when it is
**both** stale and empty:

1. List all journals in the reMarkable folder
2. Keep today's journal and any modified within `CLEANUP_KEEP_HOURS` (using the
   cloud's `ModifiedClient` time — so a journal you wrote in days later stays)
3. For older (stale) journals, download and check the largest page `.rm`:
   - an unwritten page is just the empty scene skeleton (~409 bytes)
   - writing on a page makes its `.rm` grow (typically 2600+ bytes)
4. If every page is at/below `EMPTY_RM_MAX_BYTES`, the journal is empty → deleted;
   otherwise it has writing → kept

To preview without deleting, set `CLEANUP_DRY_RUN=true` for one run and watch the
log. To disable cleanup entirely:
```yaml
- CLEANUP_ENABLED=false
```

To keep journals longer before they're eligible (e.g., 7 days):
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
2. **Runtime**: Alpine Linux. Each journal is assembled as a native reMarkable `.rmdoc` bundle — a fresh document UUID, pages cloning a blank v6 `.rm` stencil, with the chosen built-in template referenced in `.content` — then uploaded with `rmapi`. The device renders the template, so no PDF/Ghostscript is involved.
3. **Scheduling**: Uses a lightweight shell-based scheduler (no root required)
4. **Auth storage**: Persisted in Docker volume, survives container updates

## Contributing

Feel free to open issues or PRs for:
- Multiple folder support
- Weekly/monthly notebook options
- Per-page mixed templates
- Integration with other note systems
