#!/bin/bash

# =============================================================================
# Extract Errored Directories from rsync Error Log
# =============================================================================
# Parses rsync error logs to extract unique directories that failed to transfer.
# Looks for "mkstemp" errors which indicate file creation failures.
#
# Usage:
#   ./extract-errored-dirs.sh [OPTIONS] [LOG_FILE]
#
# Options:
#   --latest      Process the most recent migrate-errors log file
#   --output FILE Specify custom output file
#   --dry-run     Show what would be extracted without writing to file
#   --help        Show this help message
#
# Examples:
#   ./extract-errored-dirs.sh --latest
#   ./extract-errored-dirs.sh migrate-errors-20251219-025430.log
#   ./extract-errored-dirs.sh --output custom-output.txt --latest
# =============================================================================

set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
TIMESTAMP=$(get_timestamp)
TARGET_LOG_FILE=""
OUTPUT_FILE=""
ERROR_PREFIX="rsync: \[receiver\] mkstemp \"$DEST_BASE/"
END_OF_DIR_MARKER='/\._'

# Flags
PROCESS_LATEST=false
DRY_RUN=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 23 "$0" | tail -n 21
    exit 0
}

# =============================================================================
# Main Script
# =============================================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --latest)
            PROCESS_LATEST=true
            shift
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            ;;
        *)
            # Assume it's a log file
            TARGET_LOG_FILE="$1"
            shift
            ;;
    esac
done

# Determine input file
if [ "$PROCESS_LATEST" = true ]; then
    TARGET_LOG_FILE=$(find "$LOG_DIR" -name "migrate-errors-*.log" -type f 2>/dev/null | sort | tail -1)
    if [ -z "$TARGET_LOG_FILE" ]; then
        log_error "No migrate-errors log files found in $LOG_DIR"
        exit 1
    fi
elif [ -z "$TARGET_LOG_FILE" ]; then
    log_error "No log file specified. Use --latest or provide a log file path."
    show_help
fi

# Convert relative paths to absolute
if [[ ! "$TARGET_LOG_FILE" = /* ]]; then
    if [ -f "$LOG_DIR/$TARGET_LOG_FILE" ]; then
        TARGET_LOG_FILE="$LOG_DIR/$TARGET_LOG_FILE"
    elif [ -f "$TARGET_LOG_FILE" ]; then
        TARGET_LOG_FILE="$(realpath "$TARGET_LOG_FILE")"
    fi
fi

# Verify input file exists
if [ ! -f "$TARGET_LOG_FILE" ]; then
    log_error "Log file not found: $TARGET_LOG_FILE"
    exit 1
fi

# Set default output file if not specified
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="$LOG_DIR/errored-dirs-$TIMESTAMP.txt"
fi

log_info "Input file: $TARGET_LOG_FILE"
log_info "Output file: $OUTPUT_FILE"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No files will be written"
fi

# Extract directory paths:
# - Match lines with the error prefix
# - Use sed to extract the path between prefix and /._
# - Sort and deduplicate
recognized_count=$(grep -cE "$ERROR_PREFIX" "$TARGET_LOG_FILE" 2>/dev/null || echo "0")

log_info "Found $recognized_count rsync mkstemp errors"

# Extract unique directories
extracted_dirs=$(grep -E "$ERROR_PREFIX" "$TARGET_LOG_FILE" 2>/dev/null \
    | sed -n "s|.*${ERROR_PREFIX}\(.*\)${END_OF_DIR_MARKER}.*|\1/|p" \
    | sort -u)

dir_count=$(echo "$extracted_dirs" | grep -c . || echo "0")

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would extract $dir_count unique directories:"
    echo "$extracted_dirs" | head -20
    if [ "$dir_count" -gt 20 ]; then
        log_info "... and $((dir_count - 20)) more"
    fi
else
    echo "$extracted_dirs" > "$OUTPUT_FILE"
    log_success "Extracted $dir_count unique errored directories to $OUTPUT_FILE"
fi
