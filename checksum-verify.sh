#!/bin/bash

# =============================================================================
# Checksum Verification Script
# =============================================================================
# Reads a verify log file and performs checksum comparison on files that were
# flagged with differences (usually timestamp-only differences).
# Outputs only files that fail checksum verification (actual content mismatch).
#
# Usage:
#   ./checksum-verify.sh <verify-log-file>
#   ./checksum-verify.sh --latest              # Use most recent verify log
#
# Options:
#   --parallel N    Number of parallel checksum operations (default: 4)
#   --hash ALGO     Hash algorithm: md5, sha1, sha256 (default: md5)
#   --dry-run       Show what would be checked without running
#   --verbose       Show all files being checked, not just failures
#   --help          Show this help message
#
# Examples:
#   ./checksum-verify.sh ~/nas-migrate-logs/verify-20251220-133636.log
#   ./checksum-verify.sh --latest --verbose
#   ./checksum-verify.sh --latest --hash sha256 --parallel 8
# =============================================================================

set -euo pipefail

# Source common library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
TIMESTAMP=$(get_timestamp)
OUTPUT_FILE="$LOG_DIR/checksum-verify-$TIMESTAMP.log"
LOG_FILE="$OUTPUT_FILE"  # For the log functions

# Default options
PARALLEL_JOBS=4
HASH_ALGO="md5"
DRY_RUN=false
VERBOSE=false
INPUT_FILE=""

# Counters
TOTAL_FILES=0
CHECKED_FILES=0
PASSED_FILES=0
FAILED_FILES=0
SKIPPED_FILES=0

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 24 "$0" | tail -n 22
    exit 0
}

# Override log_pass to respect VERBOSE flag
log_pass_verbose() {
    if [ "$VERBOSE" = true ]; then
        log "${GREEN}[PASS]${NC} $1"
    fi
}

# Get the hash command based on algorithm
get_hash_cmd() {
    case "$HASH_ALGO" in
        md5)
            echo "md5sum"
            ;;
        sha1)
            echo "sha1sum"
            ;;
        sha256)
            echo "sha256sum"
            ;;
        *)
            log_error "Unknown hash algorithm: $HASH_ALGO"
            exit 1
            ;;
    esac
}

# Compute hash of a file, return just the hash
compute_hash() {
    local filepath="$1"
    local hash_cmd
    hash_cmd=$(get_hash_cmd)
    
    if [ ! -f "$filepath" ]; then
        echo "FILE_NOT_FOUND"
        return 1
    fi
    
    $hash_cmd "$filepath" 2>/dev/null | awk '{print $1}'
}

# Parse the verify log and extract file paths with their source directories
# Now expects absolute paths in the log (new format)
extract_files_from_log() {
    local log_file="$1"
    local current_src=""
    local current_dest=""
    
    while IFS= read -r line; do
        # Check for section header: === rsync differences for display_name ===
        # Now we need to look for the Source: and Dest: lines that follow
        if echo "$line" | grep -q "Verifying:"; then
            continue
        fi
        
        if echo "$line" | grep -q "Source:"; then
            current_src=$(echo "$line" | sed -n 's/.*Source: \(.*\)/\1/p' | xargs)
            continue
        fi
        
        if echo "$line" | grep -q "Dest:"; then
            current_dest=$(echo "$line" | sed -n 's/.*Dest: \(.*\)/\1/p' | xargs)
            continue
        fi
        
        # Check for file entry: >f..t...... path/to/file
        # Format: >fcstp..... where c=checksum, s=size, t=time, p=perms
        # The flags are exactly 11 characters followed by a space
        if echo "$line" | grep -q "^>f"; then
            # Extract everything after the 12th character (11 flags + 1 space)
            local filepath
            filepath=$(echo "$line" | cut -c13-)
            
            if [ -n "$current_src" ] && [ -n "$current_dest" ] && [ -n "$filepath" ]; then
                echo "${current_src}|${current_dest}|${filepath}"
            fi
        fi
    done < "$log_file"
}

# Verify a single file by checksum
# Now expects src_dir and dest_dir to be absolute paths
verify_file() {
    local src_dir="$1"
    local dest_dir="$2"
    local relative_path="$3"
    
    local src_file="$src_dir/$relative_path"
    local dest_file="$dest_dir/$relative_path"
    
    ((TOTAL_FILES++)) || true
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would check: $relative_path"
        return 0
    fi
    
    # Check if source file exists
    if [ ! -f "$src_file" ]; then
        log_warning "Source file not found: $src_file"
        ((SKIPPED_FILES++)) || true
        return 0
    fi
    
    # Check if destination file exists
    if [ ! -f "$dest_file" ]; then
        log_fail "Destination file missing: $dest_file"
        ((FAILED_FILES++)) || true
        return 1
    fi
    
    ((CHECKED_FILES++)) || true
    
    # Compute hashes
    local src_hash dest_hash
    src_hash=$(compute_hash "$src_file")
    dest_hash=$(compute_hash "$dest_file")
    
    if [ "$src_hash" = "$dest_hash" ]; then
        ((PASSED_FILES++)) || true
        log_pass_verbose "$relative_path"
        return 0
    else
        ((FAILED_FILES++)) || true
        log_fail "$relative_path"
        log_info "  Source:      $src_hash ($src_file)"
        log_info "  Destination: $dest_hash ($dest_file)"
        return 1
    fi
}

# Find the latest verify log file
find_latest_log() {
    local latest
    latest=$(ls -t "$LOG_DIR"/verify-*.log 2>/dev/null | head -1)
    
    if [ -z "$latest" ]; then
        log_error "No verify log files found in $LOG_DIR"
        exit 1
    fi
    
    echo "$latest"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                ;;
            --parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            --hash)
                HASH_ALGO="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --latest)
                INPUT_FILE=$(find_latest_log)
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                exit 1
                ;;
            *)
                INPUT_FILE="$1"
                shift
                ;;
        esac
    done
    
    if [ -z "$INPUT_FILE" ]; then
        log_error "No input file specified. Use --latest or provide a log file path."
        echo ""
        show_help
    fi
    
    if [ ! -f "$INPUT_FILE" ]; then
        log_error "Input file not found: $INPUT_FILE"
        exit 1
    fi
}

# Main function
main() {
    parse_args "$@"
    
    # Create log directory if needed
    mkdir -p "$LOG_DIR"
    
    # Print header
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           Checksum Verification for Migration                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    log_info "Output file: $OUTPUT_FILE"
    log_info "Input file: $INPUT_FILE"
    log_info "Hash algorithm: $HASH_ALGO"
    log_info "Parallel jobs: $PARALLEL_JOBS"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "Mode: DRY RUN (no actual verification)"
    fi
    
    if [ "$VERBOSE" = true ]; then
        log_info "Mode: Verbose (showing all results)"
    fi
    
    # Check that source directories exist
    check_directory_paths
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Extracting files from verify log..."
    
    # Extract files from log
    local files_list
    files_list=$(mktemp)
    extract_files_from_log "$INPUT_FILE" > "$files_list"
    
    local file_count
    file_count=$(wc -l < "$files_list")
    log_info "Found $file_count files to verify"
    
    if [ "$file_count" -eq 0 ]; then
        log_info "No files to verify. Exiting."
        rm -f "$files_list"
        exit 0
    fi
    
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Starting checksum verification..."
    echo ""
    
    # Process files
    local current_section=""
    local file_num=0
    while IFS='|' read -r src_dir dest_dir filepath; do
        ((file_num++)) || true
        
        # Print section header when directory changes
        if [ "$src_dir → $dest_dir" != "$current_section" ]; then
            current_section="$src_dir → $dest_dir"
            echo ""
            log_info "Verifying: $current_section"
        fi
        
        # Show progress every 100 files (unless verbose)
        if [ "$VERBOSE" = false ] && [ $((file_num % 100)) -eq 0 ]; then
            echo -ne "\r[$(date '+%H:%M:%S')] Progress: $file_num / $file_count files checked..."
        fi
        
        verify_file "$src_dir" "$dest_dir" "$filepath"
    done < "$files_list"
    
    # Clear progress line
    if [ "$VERBOSE" = false ]; then
        echo -ne "\r\033[K"
    fi
    
    # Cleanup
    rm -f "$files_list"
    
    # Print summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Checksum Verification Summary:"
    log_info "  Total files in log: $TOTAL_FILES"
    log_info "  Files checked:      $CHECKED_FILES"
    log_info "  Passed:             $PASSED_FILES"
    log_info "  Failed:             $FAILED_FILES"
    log_info "  Skipped:            $SKIPPED_FILES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ "$FAILED_FILES" -eq 0 ]; then
        log_success "All files passed checksum verification!"
        log_info "The timestamp differences in the verify log were false positives."
    else
        log_error "$FAILED_FILES files failed checksum verification!"
        log_info "See $OUTPUT_FILE for details."
    fi
    
    # Exit with error if there were failures
    [ "$FAILED_FILES" -eq 0 ]
}

# Run main function
main "$@"
