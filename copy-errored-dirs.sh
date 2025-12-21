#!/bin/bash

# =============================================================================
# Copy Errored Directories - Final Migration Step
# =============================================================================
# This script copies files from errored directories that rsync failed to
# transfer. Uses `cp -n` to avoid overwriting existing files.
#
# Usage:
#   ./copy-errored-dirs.sh [OPTIONS]
#
# Options:
#   --dry-run     Show what would be copied without actually copying
#   --input FILE  Specify custom input file (default: errored-dirs-*.txt)
#   --help        Show this help message
#
# Examples:
#   ./copy-errored-dirs.sh
#   ./copy-errored-dirs.sh --dry-run
#   ./copy-errored-dirs.sh --input /path/to/errored-dirs.txt
# =============================================================================

set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
TIMESTAMP=$(get_timestamp)
LOG_FILE="$LOG_DIR/copy-errored-$TIMESTAMP.log"
INPUT_FILE=""

# Flags
DRY_RUN=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 19 "$0" | tail -n 17
    exit 0
}

# Copy files from a single directory
copy_directory() {
    local dir_path="$1"
    local src_path
    src_path="$SOURCE_BASE/$(map_dest_to_source "$dir_path")"
    local dest_path="$DEST_BASE/$dir_path"

    # Verify source exists
    if [ ! -d "$src_path" ]; then
        log_warning "Source directory does not exist: $src_path"
        return 1
    fi

    # Create destination directory if it doesn't exist
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$dest_path"
    fi

    log_info "Copying: $dir_path"
    log_info "  From: $src_path"
    log_info "  To:   $dest_path"

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY RUN] Would copy files"
        # Show what files would be copied
        local file_count
        file_count=$(find "$src_path" -maxdepth 1 -type f 2>/dev/null | wc -l)
        log_info "  [DRY RUN] Found $file_count files in directory"
        return 0
    fi

    # Copy files using cp -n (no-clobber)
    # {.,}* matches both hidden and non-hidden files
    # Use nullglob to handle empty directories gracefully
    # Filter out "omitting directory" messages (subdirs already copied by rsync)
    local cp_output
    cp_output=$(bash -c "shopt -s nullglob dotglob; files=(\"$src_path\"/*); if [ \${#files[@]} -gt 0 ]; then cp -n \"\${files[@]}\" \"$dest_path/\" 2>&1; fi" 2>&1)
    local exit_code=$?
    
    # Log output, filtering directory omission messages
    if [ -n "$cp_output" ]; then
        # Check for real errors (not just "omitting directory")
        local real_errors
        real_errors=$(echo "$cp_output" | grep -v "^cp: -r not specified; omitting directory" || true)
        
        # Log directory omissions as info (they're expected)
        local omitted_dirs
        omitted_dirs=$(echo "$cp_output" | grep "^cp: -r not specified; omitting directory" || true)
        if [ -n "$omitted_dirs" ]; then
            log_info "  Skipped subdirectories (already copied by rsync)"
        fi
        
        # If there are real errors, log them and fail
        if [ -n "$real_errors" ]; then
            echo "$real_errors" | tee -a "$LOG_FILE"
            log_error "  Copy failed with exit code $exit_code"
            return $exit_code
        fi
    fi
    
    log_success "  Copied successfully"
    return 0
}

# =============================================================================
# Main Script
# =============================================================================

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --input)
            INPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        -*)
            echo -e "${RED}[ERROR]${NC} Unknown option: $1"
            show_help
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unexpected argument: $1"
            show_help
            ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Find input file if not specified
if [ -z "$INPUT_FILE" ]; then
    # Find the most recent errored-dirs file
    INPUT_FILE=$(find "$LOG_DIR" -name "errored-dirs-*.txt" -type f 2>/dev/null | sort | tail -1)
    
    if [ -z "$INPUT_FILE" ]; then
        log_error "No errored-dirs file found in $LOG_DIR"
        log_info "Specify input file with --input option"
        exit 1
    fi
fi

# Verify input file exists
if [ ! -f "$INPUT_FILE" ]; then
    log_error "Input file not found: $INPUT_FILE"
    exit 1
fi

# Start processing
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Copy Errored Directories - Final Migration           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Log file: $LOG_FILE"
log_info "Input file: $INPUT_FILE"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No files will be copied"
fi

# Check mounts
check_mounts

# Count total directories
total_dirs=$(wc -l < "$INPUT_FILE")
log_info "Found $total_dirs directories to process"
echo ""

# Process each directory
completed_count=0
skipped_count=0
failed_count=0
current=0

while IFS= read -r dir_path || [ -n "$dir_path" ]; do
    # Skip empty lines
    if [ -z "$dir_path" ]; then
        continue
    fi

    ((current++)) || true
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "[$current/$total_dirs] Processing directory"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if copy_directory "$dir_path"; then
        ((completed_count++)) || true
    else
        ((failed_count++)) || true
    fi
done < "$INPUT_FILE"

# Summary
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_info "Copy Summary:"
log_info "  Total:     $total_dirs"
log_info "  Completed: $completed_count"
log_info "  Failed:    $failed_count"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $failed_count -gt 0 ]; then
    log_warning "Some directories failed. Check log file: $LOG_FILE"
    exit 1
fi

log_success "All errored directories copied successfully!"
