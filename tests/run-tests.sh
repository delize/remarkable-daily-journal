#!/bin/bash
#
# run-tests.sh
# Local test runner for remarkable-daily-journal
#
# Usage:
#   ./tests/run-tests.sh          # Run all tests
#   ./tests/run-tests.sh lint     # Run shellcheck only
#   ./tests/run-tests.sh unit     # Run bats tests only
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check for required tools
check_dependencies() {
    local missing=()

    if ! command -v shellcheck &> /dev/null; then
        missing+=("shellcheck")
    fi

    if ! command -v bats &> /dev/null; then
        missing+=("bats")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  macOS:  brew install shellcheck bats-core"
        echo "  Ubuntu: apt-get install shellcheck bats"
        echo "  Alpine: apk add shellcheck bats"
        echo ""
        return 1
    fi

    return 0
}

# Run shellcheck on all shell scripts
run_shellcheck() {
    log_info "Running shellcheck..."

    local scripts=(
        "$PROJECT_DIR/create-daily-note.sh"
        "$PROJECT_DIR/cleanup-old-journals.sh"
        "$PROJECT_DIR/entrypoint.sh"
    )

    local failed=0

    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            echo "  Checking $(basename "$script")..."
            if ! shellcheck -e SC1091 -e SC2034 "$script"; then
                failed=1
            fi
        fi
    done

    if [ $failed -eq 0 ]; then
        log_info "shellcheck passed!"
    else
        log_error "shellcheck found issues"
        return 1
    fi
}

# Run bats unit tests
run_bats() {
    log_info "Running bats tests..."

    cd "$PROJECT_DIR"

    if [ -n "$1" ]; then
        # Run specific test file
        bats "tests/$1"
    else
        # Run all tests
        bats tests/*.bats
    fi
}

# Run syntax check on scripts
run_syntax_check() {
    log_info "Running bash syntax check..."

    local scripts=(
        "$PROJECT_DIR/create-daily-note.sh"
        "$PROJECT_DIR/cleanup-old-journals.sh"
        "$PROJECT_DIR/entrypoint.sh"
    )

    local failed=0

    for script in "${scripts[@]}"; do
        if [ -f "$script" ]; then
            echo "  Checking $(basename "$script")..."
            if ! bash -n "$script"; then
                log_error "Syntax error in $(basename "$script")"
                failed=1
            fi
        fi
    done

    if [ $failed -eq 0 ]; then
        log_info "Syntax check passed!"
    else
        return 1
    fi
}

# Main
main() {
    echo "========================================"
    echo "  reMarkable Daily Journal - Test Suite"
    echo "========================================"
    echo ""

    case "${1:-all}" in
        lint|shellcheck)
            check_dependencies || exit 1
            run_shellcheck
            ;;
        unit|bats)
            check_dependencies || exit 1
            run_bats "$2"
            ;;
        syntax)
            run_syntax_check
            ;;
        all)
            run_syntax_check
            echo ""

            if check_dependencies; then
                run_shellcheck
                echo ""
                run_bats
            else
                log_warn "Skipping shellcheck and bats tests (dependencies missing)"
                log_info "Syntax check passed - basic validation complete"
            fi
            ;;
        *)
            echo "Usage: $0 [all|lint|unit|syntax]"
            echo ""
            echo "Commands:"
            echo "  all      - Run all tests (default)"
            echo "  lint     - Run shellcheck only"
            echo "  unit     - Run bats unit tests only"
            echo "  syntax   - Run bash syntax check only"
            exit 1
            ;;
    esac

    echo ""
    log_info "All tests completed successfully!"
}

main "$@"
