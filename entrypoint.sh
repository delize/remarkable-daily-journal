#!/bin/bash
#
# entrypoint.sh
# Container entrypoint - handles authentication and scheduling
#

set -e

# Configuration
CRON_SCHEDULE="${CRON_SCHEDULE:-0 6 * * *}"  # Default: 6:00 AM daily
TZ="${TZ:-UTC}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Configuration directory
CONFIG_DIR="/app/.config/rmapi"
CONFIG_FILE="$CONFIG_DIR/rmapi.conf"

# Check if config directory is writable
check_config_writable() {
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR" 2>/dev/null || {
            log "ERROR: Cannot create config directory $CONFIG_DIR"
            log ""
            log "The config directory must be writable by the container user (UID ${PUID:-1000})."
            log "If using a bind mount, fix permissions on the host:"
            log ""
            log "  sudo chown -R ${PUID:-1000}:${PGID:-1000} /path/to/your/rmapi/directory"
            log ""
            log "Or use a named volume instead (handles permissions automatically):"
            log ""
            log "  docker run -v rmapi-config:/app/.config/rmapi ..."
            log ""
            return 1
        }
    fi

    if ! touch "$CONFIG_DIR/.write-test" 2>/dev/null; then
        log "ERROR: Config directory $CONFIG_DIR is not writable"
        log ""
        log "The config directory must be writable by the container user (UID ${PUID:-1000})."
        log "Fix permissions on the host:"
        log ""
        log "  sudo chown -R ${PUID:-1000}:${PGID:-1000} /path/to/your/rmapi/directory"
        log ""
        return 1
    fi
    rm -f "$CONFIG_DIR/.write-test"
    return 0
}

# Check if authenticated (with better error detection)
check_auth() {
    local output
    local exit_code

    # Run rmapi and capture both output and exit code
    output=$(rmapi ls / 2>&1) && exit_code=0 || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        return 0  # Authenticated
    elif [ $exit_code -eq 137 ] || [ $exit_code -eq 139 ]; then
        # 137 = SIGKILL (OOM), 139 = SIGSEGV
        log "ERROR: rmapi was killed (exit code $exit_code)"
        log "This usually means the container has insufficient memory."
        log "Increase the memory limit to at least 768MB:"
        log ""
        log "  Docker Compose: mem_limit: 768m"
        log "  Docker run: --memory=768m"
        log ""
        return 2  # Killed
    elif echo "$output" | grep -qi "unauthorized\|not authenticated\|auth"; then
        return 1  # Not authenticated
    else
        log "ERROR: rmapi failed with exit code $exit_code"
        log "Output: $output"
        return 1
    fi
}

# Export environment variables for cron
export_env() {
    # Export all REMARKABLE_* and common vars for the cron job
    env | grep -E '^(REMARKABLE_|DATE_FORMAT|TITLE_FORMAT|TEMPLATE_PAGES|CLEANUP_|SIZE_THRESHOLD|TZ|HOME|PATH)' > /app/.env 2>/dev/null || true
}

case "${1:-run}" in
    auth)
        # Interactive authentication mode
        log "Starting rmapi authentication..."

        # Check if we can write to config directory
        if ! check_config_writable; then
            exit 1
        fi

        log "Visit https://my.remarkable.com/device/browser/connect to get a one-time code"
        rmapi

        # Verify the config was saved
        if [ -f "$CONFIG_FILE" ]; then
            log "Authentication complete. Config saved to $CONFIG_DIR"
        else
            log "WARNING: Authentication may have failed - config file not found"
            log "Expected location: $CONFIG_FILE"
        fi
        ;;
    
    run)
        # One-shot mode: cleanup old journal and create today's note
        log "Running one-shot daily journal creation..."
        /app/cleanup-old-journals.sh || log "Cleanup step completed (or skipped)"
        /app/create-daily-note.sh
        ;;
    
    schedule)
        # Daemon mode: run on schedule
        log "Starting scheduled daily journal creator"
        log "Schedule: $CRON_SCHEDULE (timezone: $TZ)"
        log "Target folder: ${REMARKABLE_FOLDER:-/Daily Journal}"

        # Check if config file exists
        if [ ! -f "$CONFIG_FILE" ]; then
            log "ERROR: No authentication config found at $CONFIG_FILE"
            log ""
            log "Run authentication first:"
            log "  docker run -it --rm -v /path/to/rmapi:/app/.config/rmapi \\"
            log "    ghcr.io/delize/remarkable-daily-journal:latest auth"
            log ""
            log "If using bind mounts, ensure the directory is writable:"
            log "  sudo chown -R ${PUID:-1000}:${PGID:-1000} /path/to/rmapi"
            exit 1
        fi

        # Verify authentication works
        log "Verifying rmapi authentication..."
        if ! check_auth; then
            auth_result=$?
            if [ $auth_result -eq 2 ]; then
                # OOM - error already logged by check_auth
                exit 1
            fi
            log "ERROR: rmapi not authenticated or token expired"
            log ""
            log "Re-run authentication:"
            log "  docker run -it --rm -v /path/to/rmapi:/app/.config/rmapi \\"
            log "    ghcr.io/delize/remarkable-daily-journal:latest auth"
            exit 1
        fi
        log "✓ rmapi authentication verified"
        
        # Export environment for cron
        export_env

        log "Cron job configured. Waiting for schedule..."
        log "Next run will be at the scheduled time. Use 'run' command to trigger immediately."

        # Parse cron schedule to determine run time
        # Format: minute hour day month weekday
        CRON_MIN=$(echo "$CRON_SCHEDULE" | awk '{print $1}')
        CRON_HOUR=$(echo "$CRON_SCHEDULE" | awk '{print $2}')
        CRON_DOM=$(echo "$CRON_SCHEDULE" | awk '{print $3}')
        CRON_MON=$(echo "$CRON_SCHEDULE" | awk '{print $4}')
        CRON_DOW=$(echo "$CRON_SCHEDULE" | awk '{print $5}')

        # Simple scheduler loop (checks every minute)
        while true; do
            CURRENT_MIN=$(date +%-M)
            CURRENT_HOUR=$(date +%-H)
            CURRENT_DOM=$(date +%-d)
            CURRENT_MON=$(date +%-m)
            CURRENT_DOW=$(date +%u)  # 1=Monday, 7=Sunday

            # Check if current time matches cron schedule
            MATCH=true

            # Check minute
            if [ "$CRON_MIN" != "*" ] && [ "$CRON_MIN" != "$CURRENT_MIN" ]; then
                MATCH=false
            fi

            # Check hour
            if [ "$CRON_HOUR" != "*" ] && [ "$CRON_HOUR" != "$CURRENT_HOUR" ]; then
                MATCH=false
            fi

            # Check day of month
            if [ "$CRON_DOM" != "*" ] && [ "$CRON_DOM" != "$CURRENT_DOM" ]; then
                MATCH=false
            fi

            # Check month
            if [ "$CRON_MON" != "*" ] && [ "$CRON_MON" != "$CURRENT_MON" ]; then
                MATCH=false
            fi

            # Check day of week (convert cron 0-6 Sun-Sat to date 1-7 Mon-Sun)
            if [ "$CRON_DOW" != "*" ]; then
                # Handle both formats: 0=Sunday or 7=Sunday
                if [ "$CRON_DOW" = "0" ] || [ "$CRON_DOW" = "7" ]; then
                    [ "$CURRENT_DOW" != "7" ] && MATCH=false
                elif [ "$CRON_DOW" != "$CURRENT_DOW" ]; then
                    MATCH=false
                fi
            fi

            if [ "$MATCH" = "true" ]; then
                log "Schedule matched! Running daily journal tasks..."
                source /app/.env 2>/dev/null || true
                /app/cleanup-old-journals.sh || log "Cleanup completed (or skipped)"
                /app/create-daily-note.sh || log "Create note completed (or failed)"
                # Sleep 60s to avoid running multiple times in the same minute
                sleep 60
            fi

            # Sleep until next minute
            sleep $((60 - $(date +%S)))
        done
        ;;
    
    test)
        # Test mode: verify everything works
        log "Testing configuration..."

        # Check config directory
        if ! check_config_writable; then
            exit 1
        fi
        log "✓ Config directory writable"

        # Check config file exists
        if [ ! -f "$CONFIG_FILE" ]; then
            log "✗ Config file not found at $CONFIG_FILE"
            exit 1
        fi
        log "✓ Config file exists"

        # Check rmapi auth
        if check_auth; then
            log "✓ rmapi authentication valid"
        else
            log "✗ rmapi authentication failed"
            exit 1
        fi

        # Test with dry run
        DRY_RUN=true /app/create-daily-note.sh
        log "✓ All tests passed"
        ;;
    
    shell)
        # Drop into shell for debugging
        exec /bin/bash
        ;;
    
    *)
        echo "Usage: docker run remarkable-daily-journal [command]"
        echo ""
        echo "Commands:"
        echo "  auth      - Interactive authentication with reMarkable Cloud"
        echo "  run       - Create today's journal note (one-shot)"
        echo "  schedule  - Run as daemon, creating notes on schedule"
        echo "  test      - Verify authentication and configuration"
        echo "  shell     - Drop into bash shell for debugging"
        echo ""
        echo "Environment variables:"
        echo "  REMARKABLE_FOLDER  - Target folder (default: /Daily Journal)"
        echo "  DATE_FORMAT        - Filename date format (default: %Y-%m-%d)"
        echo "  TEMPLATE_PAGES     - Pages per notebook (default: 5)"
        echo "  TEMPLATE_STYLE     - Page style: blank, lined, grid (default: blank)"
        echo "  LINE_SPACING       - Line spacing in points (default: 24)"
        echo "  LINE_COLOR         - Line color as 'R G B' 0-1 (default: 0.85 0.85 0.85)"
        echo "  CRON_SCHEDULE      - Cron expression (default: 0 6 * * *)"
        echo "  TZ                 - Timezone (default: UTC)"
        echo ""
        echo "Cleanup settings:"
        echo "  CLEANUP_ENABLED    - Enable cleanup of unused journals (default: true)"
        echo "  CLEANUP_KEEP_DAYS  - Days to keep before cleanup eligibility (default: 1)"
        echo "  SIZE_THRESHOLD     - Fallback size threshold in bytes (default: 25000)"
        exit 1
        ;;
esac
