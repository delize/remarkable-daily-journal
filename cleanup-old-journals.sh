#!/bin/bash
#
# cleanup-old-journals.sh
# Removes the previous day's journal if it has not been modified
#
# Environment variables:
#   REMARKABLE_FOLDER - Target folder on reMarkable (default: /Daily Journal)
#   DATE_FORMAT       - Date format for filename (default: %Y-%m-%d)
#   CLEANUP_ENABLED   - Set to "true" to enable cleanup (default: true)
#   SIZE_THRESHOLD    - Files larger than this (bytes) are kept as "used" (default: 8000)
#

set -e

# Configuration from environment or defaults
REMARKABLE_FOLDER="${REMARKABLE_FOLDER:-/Daily Journal}"
DATE_FORMAT="${DATE_FORMAT:-%Y-%m-%d}"
CLEANUP_ENABLED="${CLEANUP_ENABLED:-true}"
SIZE_THRESHOLD="${SIZE_THRESHOLD:-8000}"  # Files larger than this (bytes) are considered "used"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cleanup] $*"
}

# Exit early if cleanup is disabled
if [ "$CLEANUP_ENABLED" != "true" ]; then
    log "Cleanup disabled (CLEANUP_ENABLED=$CLEANUP_ENABLED)"
    exit 0
fi

# Calculate yesterday's date (BusyBox compatible)
YESTERDAY_TIMESTAMP=$(($(date +%s) - 86400))
YESTERDAY_DATE=$(date -d "@$YESTERDAY_TIMESTAMP" +"$DATE_FORMAT" 2>/dev/null || date -r "$YESTERDAY_TIMESTAMP" +"$DATE_FORMAT")

log "Checking for unused journal from: $YESTERDAY_DATE"

# Create temp directory for operations
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Check if rmapi is authenticated
if ! rmapi ls / > /dev/null 2>&1; then
    log "ERROR: rmapi not authenticated, skipping cleanup"
    exit 0
fi

# Search for yesterday's journal
SEARCH_RESULT=$(rmapi find "$REMARKABLE_FOLDER" "^${YESTERDAY_DATE}" 2>/dev/null || true)

if [ -z "$SEARCH_RESULT" ]; then
    log "No journal found for $YESTERDAY_DATE, nothing to clean up"
    exit 0
fi

# Extract the full document path from search result
# rmapi find returns lines like: [d] /Daily Journal/2024-01-15 - Monday, January 15, 2024
DOC_PATH=$(echo "$SEARCH_RESULT" | grep "$YESTERDAY_DATE" | head -1 | sed 's/^\[[df]\] //')

if [ -z "$DOC_PATH" ]; then
    log "Could not parse document path from search results"
    exit 0
fi

DOC_NAME=$(basename "$DOC_PATH")
log "Found yesterday's journal: $DOC_NAME"

# Download yesterday's journal
log "Downloading journal for comparison..."

cd "$TEMP_DIR"
if ! rmapi get "$DOC_PATH" > /dev/null 2>&1; then
    log "Failed to download journal, skipping cleanup"
    exit 0
fi

# rmapi downloads with the document name as filename
DOWNLOADED_FILE=$(find "$TEMP_DIR" -name "*.pdf" -o -name "*.zip" 2>/dev/null | grep -v "blank_reference" | head -1)

if [ -z "$DOWNLOADED_FILE" ] || [ ! -f "$DOWNLOADED_FILE" ]; then
    log "Downloaded file not found, skipping cleanup"
    exit 0
fi

DOWNLOADED_SIZE=$(stat -f%z "$DOWNLOADED_FILE" 2>/dev/null || stat -c%s "$DOWNLOADED_FILE")
log "Downloaded journal size: $DOWNLOADED_SIZE bytes (threshold: $SIZE_THRESHOLD bytes)"

# If file is larger than threshold, it's been used - keep it
if [ "$DOWNLOADED_SIZE" -gt "$SIZE_THRESHOLD" ]; then
    log "Journal has been modified (size $DOWNLOADED_SIZE > $SIZE_THRESHOLD)"
    log "Keeping journal: $DOC_NAME"
else
    log "Journal appears unused (size $DOWNLOADED_SIZE <= $SIZE_THRESHOLD)"
    log "Removing unused journal: $DOC_PATH"

    if rmapi rm "$DOC_PATH"; then
        log "✓ Successfully removed unused journal: $DOC_NAME"
    else
        log "ERROR: Failed to remove journal"
        exit 1
    fi
fi
