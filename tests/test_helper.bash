#!/bin/bash
#
# test_helper.bash
# Common test utilities and mock functions
#

# Setup test environment
setup_test_env() {
    export TEST_MODE=true
    export TEMP_DIR=$(mktemp -d)
    export REMARKABLE_FOLDER="/Test Journal"
    export DATE_FORMAT="%Y-%m-%d"
    export TITLE_FORMAT="%A, %B %d, %Y"
    export TEMPLATE_PAGES=3
    export DRY_RUN=true
    export CLEANUP_ENABLED=true
    export SIZE_TOLERANCE=5000

    # Create mock bin directory
    export MOCK_BIN="$TEMP_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"

    # Add mock bin to PATH
    export ORIGINAL_PATH="$PATH"
    export PATH="$MOCK_BIN:$PATH"
}

# Teardown test environment
teardown_test_env() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
    export PATH="$ORIGINAL_PATH"
}

# Create mock rmapi command
create_mock_rmapi() {
    local behavior="${1:-success}"

    cat > "$MOCK_BIN/rmapi" << 'MOCK_EOF'
#!/bin/bash
# Mock rmapi for testing

MOCK_BEHAVIOR="${MOCK_RMAPI_BEHAVIOR:-success}"
MOCK_DATA_DIR="${MOCK_RMAPI_DATA_DIR:-/tmp/mock_rmapi}"

mkdir -p "$MOCK_DATA_DIR"

case "$1" in
    ls)
        if [ "$MOCK_BEHAVIOR" = "not_authenticated" ]; then
            echo "Error: not authenticated" >&2
            exit 1
        fi
        echo "[d] /Daily Journal"
        echo "[d] /Test Journal"
        ;;
    mkdir)
        echo "Created folder: $2"
        ;;
    find)
        if [ -f "$MOCK_DATA_DIR/files.txt" ]; then
            grep "$3" "$MOCK_DATA_DIR/files.txt" 2>/dev/null || true
        fi
        ;;
    put)
        echo "Uploaded: $2 to $3"
        echo "$3/$(basename "$2" .pdf)" >> "$MOCK_DATA_DIR/files.txt"
        ;;
    mv)
        echo "Renamed: $2 to $3"
        ;;
    get)
        # Simulate downloading a file
        if [ "$MOCK_BEHAVIOR" = "has_content" ]; then
            # Create a larger file to simulate content
            dd if=/dev/zero of="$PWD/downloaded.pdf" bs=1024 count=50 2>/dev/null
        else
            # Create small file to simulate blank
            dd if=/dev/zero of="$PWD/downloaded.pdf" bs=1024 count=2 2>/dev/null
        fi
        ;;
    rm)
        echo "Deleted: $2"
        ;;
    *)
        echo "Unknown command: $1"
        exit 1
        ;;
esac
MOCK_EOF

    chmod +x "$MOCK_BIN/rmapi"
    export MOCK_RMAPI_BEHAVIOR="$behavior"
    export MOCK_RMAPI_DATA_DIR="$TEMP_DIR/mock_rmapi_data"
    mkdir -p "$MOCK_RMAPI_DATA_DIR"
}

# Create mock ghostscript command
create_mock_gs() {
    cat > "$MOCK_BIN/gs" << 'MOCK_EOF'
#!/bin/bash
# Mock ghostscript for testing

# Parse output file from arguments
OUTPUT_FILE=""
for arg in "$@"; do
    if [[ "$arg" == -sOutputFile=* ]]; then
        OUTPUT_FILE="${arg#-sOutputFile=}"
    fi
done

if [ -n "$OUTPUT_FILE" ]; then
    # Create a small valid-ish PDF
    echo "%PDF-1.4 mock pdf content" > "$OUTPUT_FILE"
fi
MOCK_EOF

    chmod +x "$MOCK_BIN/gs"
}

# Assert file exists
assert_file_exists() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "FAIL: File does not exist: $file" >&2
        return 1
    fi
}

# Assert file contains string
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    if ! grep -q "$pattern" "$file"; then
        echo "FAIL: File $file does not contain: $pattern" >&2
        return 1
    fi
}

# Assert command output contains string
assert_output_contains() {
    local output="$1"
    local pattern="$2"
    if ! echo "$output" | grep -q "$pattern"; then
        echo "FAIL: Output does not contain: $pattern" >&2
        echo "Output was: $output" >&2
        return 1
    fi
}
