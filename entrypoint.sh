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

# Health classification lives in rmapi-health.sh so entrypoint.sh,
# create-daily-note.sh and cleanup-old-journals.sh all agree on what a failure
# means. Codes: 0 healthy, 1 unauthenticated, 2 killed (OOM), 3 cloud/API
# error, 4 rate limited (HTTP 429).
# shellcheck source=rmapi-health.sh
ENTRYPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ENTRYPOINT_DIR/rmapi-health.sh"

# Wrapper that keeps the historical name and adds the explanatory logging.
check_auth() {
    local rc=0
    rmapi_check_health || rc=$?
    [ "$rc" -eq 0 ] || rmapi_explain_health "$rc"
    return "$rc"
}

# Export environment variables for cron
export_env() {
    # Export all REMARKABLE_* and common vars (incl. GitHub reporting) so the
    # scheduler loop subshell sees them after `source /app/.env`.
    env | grep -E '^(REMARKABLE_|DATE_FORMAT|JOURNAL_|TEMPLATE_|CLEANUP_|EMPTY_RM_MAX_BYTES|SIZE_THRESHOLD|RMAPI_RATE_LIMIT_|TZ|HOME|PATH|GITHUB_|GH_TOKEN)' > /app/.env 2>/dev/null || true
}

# Fire a health notification (no-op unless github-notify.sh is configured).
notify() {
    [ -x /app/github-notify.sh ] || return 0
    /app/github-notify.sh "$@" || log "WARN: github-notify failed"
}

# Build a markdown issue body: description + timestamp + the rmapi output.
notify_body() {
    printf '%s\n\n- Detected: %s\n- Host: %s\n\nrmapi output:\n```\n%s\n```\n' \
        "$1" "$(date -u '+%Y-%m-%d %H:%M UTC')" "$(hostname)" "${LAST_RMAPI_OUTPUT:-<none>}"
}

# One health-check + journal cycle, with notifications. Used at startup and on
# every scheduled run so failures are reported and recoveries auto-close issues.
# Returns: 0 = healthy (journal ran), 2 = OOM, 1 = unhealthy.
cycle() {
    local rc=0
    # Re-verify each cycle rather than trusting a flag set hours ago.
    unset RMAPI_HEALTH_VERIFIED
    check_auth || rc=$?
    case "$rc" in
        0)
            log "✓ rmapi authentication verified"
            # The child scripts skip their own health check on the strength of
            # this one, so a cycle costs one token exchange instead of three.
            export RMAPI_HEALTH_VERIFIED=true

            # Create FIRST, clean up after. Cleanup is optional maintenance and
            # must never be able to spend the reMarkable rate-limit budget that
            # journal creation needs: a cleanup pass that 429s used to take the
            # creation that followed it down with it.
            if /app/create-daily-note.sh; then
                notify ok
            else
                log "ERROR: journal creation failed despite a healthy auth check"
                notify failing error \
                    "$(notify_body 'Daily journal creation failed even though the rmapi auth/sync check passed. Inspect container logs.')"
            fi
            /app/cleanup-old-journals.sh || log "Cleanup completed (or skipped)"
            unset RMAPI_HEALTH_VERIFIED
            return 0
            ;;
        2)
            # OOM — check_auth already logged the memory guidance.
            return 2
            ;;
        3)
            log "WARNING: reMarkable cloud API/sync error (e.g. HTTP 400) — see output above."
            log "If this persists, rebuild so rmapi is built from a current commit."
            notify failing api \
                "$(notify_body 'reMarkable cloud API error (HTTP 4xx/5xx or "failed to mirror"). The rmapi sync check failed, so the daily journal cannot run. A 400 here is an API mismatch, not token expiry — rebuild rmapi from a current commit.')"
            return 1
            ;;
        4)
            log "WARNING: reMarkable rate-limited us (HTTP 429) even after backing off."
            log "Nothing ran this cycle. The limit clears on its own; the next run should succeed."
            notify failing api \
                "$(notify_body 'reMarkable returned HTTP 429 (rate limited) on the token exchange, and it was still limiting us after the backoff retries. No journal was created this cycle. This is NOT token expiry — do not re-auth. It clears on its own.')"
            return 1
            ;;
        *)
            log "WARNING: rmapi not authenticated / token problem — re-auth needed."
            notify failing auth \
                "$(notify_body 'rmapi reports it is not authenticated (token problem). Re-run the container'\''s auth command to refresh the device token.')"
            return 1
            ;;
    esac
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
        # One-shot mode: create today's note, then clean up.
        # Creation runs first so the optional cleanup pass can never spend the
        # reMarkable rate-limit budget that creation needs.
        log "Running one-shot daily journal creation..."
        run_rc=0
        check_auth || run_rc=$?
        if [ "$run_rc" -ne 0 ]; then
            log "ERROR: rmapi health check failed (code $run_rc), not running"
            exit 1
        fi
        export RMAPI_HEALTH_VERIFIED=true
        /app/create-daily-note.sh
        /app/cleanup-old-journals.sh || log "Cleanup step completed (or skipped)"
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

        # Export environment first so the scheduler loop subshell and the
        # health notifier both see it after `source /app/.env`.
        export_env

        # Run one health-check + journal cycle now. cycle() reports failures to
        # GitHub (if configured) and never exits on auth/API errors, so a
        # transient cloud outage cannot crash-loop the container under
        # `restart: unless-stopped`. Only OOM (rc=2) is fatal.
        log "Verifying rmapi authentication and running startup cycle..."
        startup_rc=0
        cycle || startup_rc=$?
        if [ "$startup_rc" -eq 2 ]; then
            exit 1
        fi

        log "Cron job configured. Waiting for schedule..."
        log "Next run will be at the scheduled time."

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
                # cycle() health-checks, runs the journal, and reports/clears
                # GitHub issues. Never let a failure break the scheduler loop.
                cycle || true
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
        echo "  TEMPLATE_PAGES     - Pages per notebook (default: 1)"
        echo "  TEMPLATE_STYLE     - Template: blank, lined, grid, checklist, or a"
        echo "                       raw reMarkable template name (default: lined)"
        echo "  TEMPLATE_HARDWARE  - Device list to validate against: rmpp/rm2/rm1 (default: rmpp)"
        echo "  CRON_SCHEDULE      - Cron expression (default: 0 6 * * *)"
        echo "  TZ                 - Timezone (default: UTC)"
        echo ""
        echo "Cleanup settings:"
        echo "  CLEANUP_ENABLED    - Enable cleanup of unused journals (default: true)"
        echo "  CLEANUP_KEEP_HOURS - Keep journals modified within this many hours (default: 48)"
        echo "  CLEANUP_MAX_DOCS   - Most journals to download in one pass (default: 5)"
        echo "  CLEANUP_API_DELAY_SECONDS"
        echo "                     - Seconds between rmapi calls in the cleanup loop (default: 2)"
        echo "  EMPTY_RM_MAX_BYTES - Page .rm at/below this size counts as empty (default: 1000)"
        echo "  SIZE_THRESHOLD     - Fallback size threshold in bytes (default: 25000)"
        echo "  CLEANUP_DRY_RUN    - Log deletions without removing anything (default: false)"
        exit 1
        ;;
esac
