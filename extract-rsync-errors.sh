#!/bin/bash

# =============================================================================
# Extract rsync Errors from Migration Logs
# =============================================================================
# This script extracts lines containing rsync errors from migration log files
# and saves them to a separate error log file.
#
# Usage:
#   ./extract-rsync-errors.sh [OPTIONS] [LOG_FILES...]
#
# Options:
#   --all         Process all log files in the nas-migrate-logs directory
#   --latest      Process only the most recent log file
#   --output FILE Specify custom output file (default: migrate-errors-TIMESTAMP.log)
#   --dry-run     Show what would be done without writing output file
#   --help        Show this help message
#
# Examples:
#   ./extract-rsync-errors.sh --all
#   ./extract-rsync-errors.sh --latest
#   ./extract-rsync-errors.sh migrate-20251215-215652.log
#   ./extract-rsync-errors.sh --output errors.log --all
# =============================================================================

set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
TIMESTAMP=$(get_timestamp)
OUTPUT_FILE=""

# Flags
PROCESS_ALL=false
PROCESS_LATEST=false
DRY_RUN=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 22 "$0" | tail -n 20
    exit 0
}

# Extract errors from a single log file
# Returns error count via global variable LAST_ERROR_COUNT
extract_errors() {
    local log_file="$1"
    LAST_ERROR_COUNT=0
    
    if [ ! -f "$log_file" ]; then
        log_error "File not found: $log_file"
        return 1
    fi
    
    # Extract lines containing rsync errors and clean them up
    # Common patterns:
    #   - rsync: [receiver] ...
    #   - rsync: [sender] ...
    #   - rsync: [generator] ...
    #   - rsync error: ...
    #
    # Lines often have progress stats prepended like:
    #   "2.03T  99%   22.52MB/s   23:51:30 (xfr#22254, ir-chk=1136/23530)rsync: [receiver] ..."
    # We extract only the "rsync: ..." or "rsync error: ..." portion
    local errors
    errors=$(grep -oE "rsync: \[[a-z]+\] [^$]+" "$log_file" 2>/dev/null || true)
    
    # Also capture standalone "rsync error:" lines
    local error_summary
    error_summary=$(grep -E "^rsync error:" "$log_file" 2>/dev/null || true)
    
    # Combine and deduplicate
    local all_errors
    if [ -n "$errors" ] && [ -n "$error_summary" ]; then
        all_errors=$(printf "%s\n%s" "$errors" "$error_summary" | sort -u)
    elif [ -n "$errors" ]; then
        all_errors=$(echo "$errors" | sort -u)
    elif [ -n "$error_summary" ]; then
        all_errors=$(echo "$error_summary" | sort -u)
    else
        all_errors=""
    fi
    
    if [ -n "$all_errors" ]; then
        LAST_ERROR_COUNT=$(echo "$all_errors" | wc -l)
        echo "" >> "$OUTPUT_FILE"
        echo "# =============================================================================" >> "$OUTPUT_FILE"
        echo "# Source: $(basename "$log_file")" >> "$OUTPUT_FILE"
        echo "# Errors found: $LAST_ERROR_COUNT" >> "$OUTPUT_FILE"
        echo "# =============================================================================" >> "$OUTPUT_FILE"
        echo "$all_errors" >> "$OUTPUT_FILE"
        log_info "Extracted $LAST_ERROR_COUNT errors from $(basename "$log_file")"
    else
        log_info "No rsync errors found in $(basename "$log_file")"
    fi
}

# =============================================================================
# Main Script
# =============================================================================

# Parse command line arguments
LOG_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            PROCESS_ALL=true
            shift
            ;;
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
            LOG_FILES+=("$1")
            shift
            ;;
    esac
done

# Check log directory exists
if [ ! -d "$LOG_DIR" ]; then
    log_error "Log directory not found: $LOG_DIR"
    exit 1
fi

# Determine which files to process
if [ "$PROCESS_ALL" = true ]; then
    # Exclude error log files (migrate-errors-*.log) from processing
    mapfile -t LOG_FILES < <(find "$LOG_DIR" -name "migrate-*.log" ! -name "migrate-errors-*.log" -type f | sort)
elif [ "$PROCESS_LATEST" = true ]; then
    latest=$(find "$LOG_DIR" -name "migrate-*.log" ! -name "migrate-errors-*.log" -type f | sort | tail -1)
    if [ -n "$latest" ]; then
        LOG_FILES=("$latest")
    fi
elif [ ${#LOG_FILES[@]} -eq 0 ]; then
    log_error "No log files specified. Use --all, --latest, or provide file names."
    echo ""
    show_help
fi

# Convert relative paths to absolute paths
for i in "${!LOG_FILES[@]}"; do
    file="${LOG_FILES[$i]}"
    if [[ ! "$file" = /* ]]; then
        # Check if it's in the log directory
        if [ -f "$LOG_DIR/$file" ]; then
            LOG_FILES[$i]="$LOG_DIR/$file"
        elif [ -f "$file" ]; then
            LOG_FILES[$i]="$(realpath "$file")"
        fi
    fi
done

# Set default output file if not specified
if [ -z "$OUTPUT_FILE" ]; then
    OUTPUT_FILE="$LOG_DIR/migrate-errors-$TIMESTAMP.log"
fi

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Start extraction
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           Extract rsync Errors from Migration Logs           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Processing ${#LOG_FILES[@]} log file(s)"
log_info "Output file: $OUTPUT_FILE"
if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No output file will be written"
fi
echo ""

# In dry-run mode, just show what would be processed
if [ "$DRY_RUN" = true ]; then
    log_info "Files that would be processed:"
    for log_file in "${LOG_FILES[@]}"; do
        echo "  - $(basename "$log_file")"
    done
    echo ""
    log_info "DRY RUN complete. No files were written."
    exit 0
fi

# Initialize output file with header
cat > "$OUTPUT_FILE" << EOF
# =============================================================================
# rsync Error Log - Extracted $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
# This file contains rsync errors extracted from migration logs.
# 
# Common error patterns:
#   - rsync: [receiver] mkstemp ... failed: No such file or directory
#     (Usually caused by special characters or long filenames)
#   - rsync: [sender] ... Permission denied
#   - rsync error: some files/attrs were not transferred
# =============================================================================
EOF

# Process each log file
total_errors=0
LAST_ERROR_COUNT=0

for log_file in "${LOG_FILES[@]}"; do
    extract_errors "$log_file"
    total_errors=$((total_errors + LAST_ERROR_COUNT))
done

# Summary
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_info "Extraction Summary:"
log_info "  Files processed: ${#LOG_FILES[@]}"
log_info "  Total errors:    $total_errors"
log_info "  Output file:     $OUTPUT_FILE"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $total_errors -gt 0 ]; then
    log_success "Errors extracted to: $OUTPUT_FILE"
    echo ""
    echo "To view errors:"
    echo "  less $OUTPUT_FILE"
    echo ""
    echo "To list unique error files:"
    echo "  grep -oP '(?<=mkstemp \")[^\"]+' $OUTPUT_FILE | sort -u"
else
    log_info "No rsync errors found in any log files."
    # Remove empty output file
    rm -f "$OUTPUT_FILE"
fi
