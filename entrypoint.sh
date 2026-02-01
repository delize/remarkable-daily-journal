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

# Export environment variables for cron
export_env() {
    # Export all REMARKABLE_* and common vars for the cron job
    env | grep -E '^(REMARKABLE_|DATE_FORMAT|TITLE_FORMAT|TEMPLATE_PAGES|CLEANUP_|SIZE_TOLERANCE|TZ|HOME|PATH)' > /app/.env 2>/dev/null || true
}

case "${1:-run}" in
    auth)
        # Interactive authentication mode
        log "Starting rmapi authentication..."
        log "Visit https://my.remarkable.com/device/browser/connect to get a one-time code"
        rmapi
        log "Authentication complete. Config saved to /app/.config/rmapi"
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
        
        # Verify authentication
        if ! rmapi ls / > /dev/null 2>&1; then
            log "ERROR: rmapi not authenticated!"
            log "Run: docker run -it -v rmapi-config:/app/.config/rmapi remarkable-daily-journal auth"
            exit 1
        fi
        log "✓ rmapi authentication verified"
        
        # Export environment for cron
        export_env
        
        # Create crontab
        cat > /app/crontab << EOF
# reMarkable Daily Journal
# Runs at: $CRON_SCHEDULE
# First cleanup unused previous day's journal, then create new one
$CRON_SCHEDULE /bin/bash -c 'source /app/.env 2>/dev/null; /app/cleanup-old-journals.sh; /app/create-daily-note.sh' >> /proc/1/fd/1 2>&1
EOF
        
        log "Cron job configured. Waiting for schedule..."
        log "Next run will be at the scheduled time. Use 'run' command to trigger immediately."
        
        # Run supercrond (alpine's cron daemon)
        exec supercrond -config /app/crontab
        ;;
    
    test)
        # Test mode: verify everything works
        log "Testing configuration..."
        
        # Check rmapi auth
        if rmapi ls / > /dev/null 2>&1; then
            log "✓ rmapi authentication valid"
        else
            log "✗ rmapi not authenticated"
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
        echo "  TITLE_FORMAT       - Display title format (default: %A, %B %d, %Y)"
        echo "  TEMPLATE_PAGES     - Pages per notebook (default: 5)"
        echo "  CRON_SCHEDULE      - Cron expression (default: 0 6 * * *)"
        echo "  TZ                 - Timezone (default: UTC)"
        echo ""
        echo "Cleanup settings:"
        echo "  CLEANUP_ENABLED    - Enable cleanup of unused journals (default: true)"
        echo "  SIZE_TOLERANCE     - Max size diff in bytes to consider unused (default: 5000)"
        exit 1
        ;;
esac
