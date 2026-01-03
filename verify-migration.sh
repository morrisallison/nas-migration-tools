#!/bin/bash

# =============================================================================
# NAS Migration Verification Script
# =============================================================================
# Verifies that files were correctly migrated from source to destination NAS.
# Uses rsync dry-run (size + mtime comparison) and random file sampling.
#
# Usage:
#   ./verify-migration.sh [OPTIONS] [DIRECTORIES...]
#
# Options:
#   --sample N      Number of random files to verify with cmp (default: 100)
#   --bwlimit N     Bandwidth limit in KB/s for rsync (default: no limit)
#   --rsync-only    Only run rsync comparison, skip sampling
#   --sample-only   Only run random sampling, skip rsync
#   --summary-only  Only show file count and size comparison
#   --dry-run       Show what would be done without running verification
#   --help          Show this help message
#
# Examples:
#   ./verify-migration.sh                    # Verify all directories
#   ./verify-migration.sh music photos       # Verify specific directories
#   ./verify-migration.sh --sample 500       # Sample 500 random files
#   ./verify-migration.sh --bwlimit 50000    # Limit to 50 MB/s
#   ./verify-migration.sh --summary-only     # Quick sanity check
# =============================================================================

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Log file for this run
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/verify-$TIMESTAMP.log"

# Default options
SAMPLE_COUNT=100
BWLIMIT=""
RSYNC_ONLY=false
SAMPLE_ONLY=false
SUMMARY_ONLY=false
DRY_RUN=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 26 "$0" | tail -n 24
    exit 0
}

# Show file count and size summary for a directory
show_summary() {
    local src_path="$1"
    local dest_path="$2"
    local display_name
    display_name=$(get_dir_display_name "$src_path")

    if [ ! -d "$src_path" ]; then
        log_warning "Source directory does not exist: $src_path"
        return 1
    fi

    if [ ! -d "$dest_path" ]; then
        log_warning "Destination directory does not exist: $dest_path"
        return 1
    fi

    log_info "Comparing: $display_name"

    # Use ionice for low I/O priority
    local src_count src_size dest_count dest_size

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY RUN] Would count files in $src_path and $dest_path"
        return 0
    fi

    src_count=$(ionice -c 3 find "$src_path" -type f 2>/dev/null | wc -l)
    dest_count=$(ionice -c 3 find "$dest_path" -type f 2>/dev/null | wc -l)

    src_size=$(ionice -c 3 du -sh "$src_path" 2>/dev/null | cut -f1)
    dest_size=$(ionice -c 3 du -sh "$dest_path" 2>/dev/null | cut -f1)

    local status_icon
    if [ "$src_count" -eq "$dest_count" ]; then
        status_icon="${GREEN}✓${NC}"
    else
        status_icon="${RED}✗${NC}"
    fi

    log_info "  Source:      $src_count files, $src_size"
    log_info "  Destination: $dest_count files, $dest_size"

    if [ "$src_count" -ne "$dest_count" ]; then
        local diff=$((src_count - dest_count))
        log_warning "  Difference: $diff files"
        return 1
    else
        log_success "  File counts match"
        return 0
    fi
}

# Run rsync dry-run comparison
run_rsync_verify() {
    local src_path="$1"
    local dest_path="$2"
    local display_name
    display_name=$(get_dir_display_name "$src_path")

    if [ ! -d "$src_path" ]; then
        log_warning "Source directory does not exist: $src_path"
        return 1
    fi

    log_info "rsync verification: $display_name"

    local rsync_opts=(
        --archive
        --dry-run
        --itemize-changes
        --stats
        --human-readable
        --exclude=".rsync-partial"
        --exclude="Thumbs.db"
        --exclude=".DS_Store"
        --exclude="desktop.ini"
    )

    if [ -n "$BWLIMIT" ]; then
        rsync_opts+=(--bwlimit="$BWLIMIT")
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY RUN] Would run: ionice -c 3 nice -n 19 rsync ${rsync_opts[*]} \"$src_path/\" \"$dest_path/\""
        return 0
    fi

    # Run rsync with low priority, capture output
    local output
    output=$(ionice -c 3 nice -n 19 rsync "${rsync_opts[@]}" "$src_path/" "$dest_path/" 2>&1)

    # Count files that would be transferred (lines starting with > or c)
    local changes
    changes=$(echo "$output" | grep -c "^[>c]" || echo "0")

    if [ "$changes" -eq 0 ]; then
        log_success "  No differences found"
        return 0
    else
        log_warning "  Found $changes files with differences"
        
        # Log all differences to log file
        echo "" >> "$LOG_FILE"
        echo "=== rsync differences for $display_name ===" >> "$LOG_FILE"
        echo "$output" | grep "^[>c]" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        
        # Show first 10 differences on screen
        echo "$output" | grep "^[>c]" | head -10 | while read -r line; do
            echo -e "    $line"
        done
        if [ "$changes" -gt 10 ]; then
            log_info "    ... and $((changes - 10)) more (see log file for full list)"
        fi
        return 1
    fi
}

# Run random file sampling with cmp
run_sample_verify() {
    local src_path="$1"
    local dest_path="$2"
    local display_name
    display_name=$(get_dir_display_name "$dest_path")

    if [ ! -d "$dest_path" ]; then
        log_warning "Destination directory does not exist: $dest_path"
        return 1
    fi

    log_info "Random sampling: $display_name ($SAMPLE_COUNT files)"

    if [ "$DRY_RUN" = true ]; then
        log_info "  [DRY RUN] Would sample $SAMPLE_COUNT random files from $dest_path"
        return 0
    fi

    # Get random sample of files from destination
    local sample_files
    sample_files=$(ionice -c 3 find "$dest_path" -type f 2>/dev/null | shuf -n "$SAMPLE_COUNT")

    if [ -z "$sample_files" ]; then
        log_warning "  No files found to sample"
        return 0
    fi

    local total=0
    local matched=0
    local mismatched=0
    local missing=0
    local mismatch_list=()

    while IFS= read -r dest_file; do
        [ -z "$dest_file" ] && continue
        ((total++)) || true

        # Map destination file to source file
        local rel_path="${dest_file#$dest_path/}"
        local src_file="$src_path/$rel_path"

        if [ ! -f "$src_file" ]; then
            ((missing++)) || true
            mismatch_list+=("MISSING: $src_rel_path")
        elif ionice -c 3 cmp -s "$src_file" "$dest_file"; then
            ((matched++)) || true
        else
            ((mismatched++)) || true
            mismatch_list+=("MISMATCH: $rel_path")
        fi
    done <<< "$sample_files"

    log_info "  Sampled: $total files"
    log_info "  Matched: $matched"

    if [ "$missing" -gt 0 ]; then
        log_warning "  Missing from source: $missing"
    fi

    if [ "$mismatched" -gt 0 ]; then
        log_error "  Content mismatch: $mismatched"
    fi

    # Log all mismatches to log file, show first few on screen
    if [ ${#mismatch_list[@]} -gt 0 ]; then
        # Log all to file
        echo "" >> "$LOG_FILE"
        echo "=== Sample mismatches for $display_name ===" >> "$LOG_FILE"
        for item in "${mismatch_list[@]}"; do
            echo "  $item" >> "$LOG_FILE"
        done
        echo "" >> "$LOG_FILE"
        
        # Show first few on screen
        local show_count=5
        for ((i = 0; i < ${#mismatch_list[@]} && i < show_count; i++)); do
            log_warning "    ${mismatch_list[$i]}"
        done
        if [ ${#mismatch_list[@]} -gt $show_count ]; then
            log_info "    ... and $((${#mismatch_list[@]} - show_count)) more (see log file for full list)"
        fi
        return 1
    fi

    log_success "  All sampled files verified"
    return 0
}

# Verify a single directory
verify_directory() {
    local src_path="$1"
    local dest_path="$2"
    local display_name
    display_name=$(get_dir_display_name "$src_path")

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Verifying: $display_name"
    log_info "  Source: $src_path"
    log_info "  Dest:   $dest_path"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local has_errors=false

    # Summary comparison
    if ! show_summary "$src_path" "$dest_path"; then
        has_errors=true
    fi

    # rsync verification
    if [ "$SUMMARY_ONLY" = false ] && [ "$SAMPLE_ONLY" = false ]; then
        if ! run_rsync_verify "$src_path" "$dest_path"; then
            has_errors=true
        fi
    fi

    # Random sampling
    if [ "$SUMMARY_ONLY" = false ] && [ "$RSYNC_ONLY" = false ]; then
        if ! run_sample_verify "$src_path" "$dest_path"; then
            has_errors=true
        fi
    fi

    if [ "$has_errors" = true ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Main Script
# =============================================================================

# Parse command line arguments
declare -a SELECTED_INDICES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample)
            SAMPLE_COUNT="$2"
            shift 2
            ;;
        --bwlimit)
            BWLIMIT="$2"
            shift 2
            ;;
        --rsync-only)
            RSYNC_ONLY=true
            shift
            ;;
        --sample-only)
            SAMPLE_ONLY=true
            shift
            ;;
        --summary-only)
            SUMMARY_ONLY=true
            shift
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
            # Assume it's a directory index or name
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                if [ "$1" -lt "${#DIR_SOURCES[@]}" ]; then
                    SELECTED_INDICES+=("$1")
                else
                    log_error "Invalid directory index: $1 (max: $((${#DIR_SOURCES[@]} - 1)))"
                    exit 1
                fi
            else
                # Try to match by basename
                local found=false
                for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
                    if [[ "$(get_dir_display_name "${DIR_SOURCES[$i]}")" == "$1" ]]; then
                        SELECTED_INDICES+=("$i")
                        found=true
                        break
                    fi
                done
                if [ "$found" = false ]; then
                    log_error "Unknown directory: $1"
                    echo "Use migrate-files.sh --status to see available directories"
                    exit 1
                fi
            fi
            shift
            ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Use all directories if none specified
if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
    for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
        SELECTED_INDICES+=("$i")
    done
fi

# Start verification
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║          NAS Migration Verification                          ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Log file: $LOG_FILE"
log_info "Directories to verify: ${#SELECTED_INDICES[@]}"
log_info "Sample count: $SAMPLE_COUNT"
[ -n "$BWLIMIT" ] && log_info "Bandwidth limit: ${BWLIMIT} KB/s"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual verification will be performed"
fi

if [ "$SUMMARY_ONLY" = true ]; then
    log_info "Mode: Summary only (file count + size)"
elif [ "$RSYNC_ONLY" = true ]; then
    log_info "Mode: rsync only (size + mtime)"
elif [ "$SAMPLE_ONLY" = true ]; then
    log_info "Mode: Random sampling only"
else
    log_info "Mode: Full verification (rsync + sampling)"
fi

# Check that source directories exist
check_directory_paths

# Process directories
passed_count=0
failed_count=0

for idx in "${SELECTED_INDICES[@]}"; do
    local src="${DIR_SOURCES[$idx]}"
    local dest="${DIR_DESTINATIONS[$idx]}"
    
    if verify_directory "$src" "$dest"; then
        ((passed_count++)) || true
    else
        ((failed_count++)) || true
    fi
done

# Summary
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_info "Verification Summary:"
log_info "  Passed: $passed_count"
log_info "  Failed: $failed_count"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $failed_count -gt 0 ]; then
    log_warning "Some directories have differences. Check log file: $LOG_FILE"
    exit 1
fi

log_success "All directories verified successfully!"
