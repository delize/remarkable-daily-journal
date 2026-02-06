# reMarkable Daily Journal - Docker

Automatically creates dated notebooks on your reMarkable tablet, running as a Docker container.

## Features

- 📅 Creates a new dated notebook every day
- 🔄 Runs on a configurable schedule (default: 6:00 AM)
- 🐳 Runs as a lightweight Docker container
- 💾 Persistent authentication (survives container restarts)
- ⏭️ Skips if notebook for that date already exists
- 🕐 Timezone-aware scheduling
- 🧹 Auto-cleanup of unused journals (scans and removes unwritten journals)

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
  
  # Filename format (ISO date recommended for sorting)
  - DATE_FORMAT=%Y-%m-%d
  
  # Display title format
  # %A = weekday name, %B = month name, %d = day, %Y = year
  - TITLE_FORMAT=%A, %B %d, %Y
  
  # Pages per notebook
  - TEMPLATE_PAGES=5

  # Cleanup settings
  # Automatically remove old journals that were never written in
  - CLEANUP_ENABLED=true

  # Days to keep journals before they become eligible for cleanup
  - CLEANUP_KEEP_DAYS=1
```

### Cleanup Behavior

When the scheduled job runs (or when you run `run` manually), it will:

1. List all journals in the reMarkable folder
2. Skip today's journal and any within `CLEANUP_KEEP_DAYS`
3. Download each older journal and inspect it for handwriting annotations
4. If the document contains `.rm` annotation files (Remarkable's handwriting format), it's been used and is kept
5. If no annotations are found, the journal is unused and deleted

This prevents accumulation of empty journal pages while preserving any journals you've actually used.

To disable cleanup:
```yaml
- CLEANUP_ENABLED=false
```

To keep journals for longer before cleanup (e.g., 7 days):
```yaml
- CLEANUP_KEEP_DAYS=7
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

Notebooks are created with this naming pattern:

```
2025-02-01 - Sunday, February 01, 2025
```

This format:
- Sorts chronologically in reMarkable's file list
- Shows the full date at a glance
- Works well with Obsidian daily notes if you're syncing

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
│       └── ci.yml              # Full CI/CD pipeline
├── tests/
│   ├── create-daily-note.bats  # Tests for create-daily-note.sh
│   ├── cleanup-old-journals.bats # Tests for cleanup-old-journals.sh
│   ├── entrypoint.bats         # Tests for entrypoint.sh
│   └── run-tests.sh            # Local test runner
├── Dockerfile                  # Multi-stage build with rmapi
├── docker-compose.yml          # Service definition
├── create-daily-note.sh        # Creates daily journal notebooks
├── cleanup-old-journals.sh     # Removes unused previous day journals
├── entrypoint.sh               # Container entrypoint
├── .gitignore                  # Git ignore patterns
└── README.md                   # This file
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
Stage 2: Unit Tests    → Bats test suite with mocked dependencies
    ↓
Stage 3: Docker Build  → Build image + integration tests (dry run)
    ↓
Stage 4: Push          → Multi-arch build (amd64 + arm64) → GHCR
```

Push stage only runs on `main` branch and version tags, not on PRs.

## How It Works

1. **Build stage**: Compiles `rmapi` from the [ddvk/rmapi](https://github.com/ddvk/rmapi) fork (actively maintained)
2. **Runtime**: Alpine Linux with ghostscript for PDF generation
3. **Scheduling**: Uses a lightweight shell-based scheduler (no root required)
4. **Auth storage**: Persisted in Docker volume, survives container updates

## Contributing

Feel free to open issues or PRs for:
- Custom template support (lined, dotted, etc.)
- Multiple folder support
- Weekly/monthly notebook options
- Integration with other note systems
