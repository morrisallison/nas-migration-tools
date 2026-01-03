#!/bin/bash

# =============================================================================
# NAS Migration Script
# =============================================================================
# This script copies files from the source NAS to the destination NAS
# using rsync for efficient, resumable transfers with size-based comparison.
# Optimized for initial migration where most files don't exist on destination.
#
# Performance Notes:
#   - Uses --size-only for fast comparison (no checksumming)
#   - Disables compression (media files already compressed)
#   - Uses whole-file transfer for LAN speed
#   - For verification after migration, run with --checksum manually
#
# Usage:
#   ./migrate-files.sh [OPTIONS] [DIRECTORIES...]
#
# Options:
#   --dry-run     Show what would be transferred without actually copying
#   --size-only   Compare files by size only (faster, skips mtime check)
#   --resume      Skip directories marked as completed in progress file
#   --status      Show migration status and exit
#   --reset       Clear progress file and start fresh
#   --help        Show this help message
#
# Examples:
#   ./migrate-files.sh                    # Migrate all directories
#   ./migrate-files.sh music videos       # Migrate only music and videos
#   ./migrate-files.sh --dry-run          # Preview what would be copied
#   ./migrate-files.sh --resume           # Resume interrupted migration
# =============================================================================

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
PROGRESS_FILE="$HOME/.nas-migrate-progress"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/migrate-$TIMESTAMP.log"

# Flags
DRY_RUN=false
SIZE_ONLY=false
RESUME=false
SHOW_STATUS=false
RESET_PROGRESS=false
INTERRUPTED=false

# Selected directories (by index)
declare -a SELECTED_INDICES=()

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 24 "$0" | tail -n 22
    exit 0
}

# Signal handler for graceful interruption
handle_interrupt() {
    echo ""
    log_warning "Received interrupt signal (Ctrl+C)"
    log_info "Migration paused. Current transfer will stop after completing current file."
    log_info "Run with --resume to continue from where you left off."
    INTERRUPTED=true
    exit 130
}

# Set up signal handlers
trap handle_interrupt SIGINT SIGTERM

# Check if a directory has been completed (by source path)
is_completed() {
    local src_path="$1"
    # Use hash of path for progress tracking to handle special chars
    local path_id
    path_id=$(echo -n "$src_path" | md5sum | cut -d' ' -f1)
    if [ -f "$PROGRESS_FILE" ]; then
        grep -q "^$path_id:completed:" "$PROGRESS_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

# Mark a directory as completed
mark_completed() {
    local src_path="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local path_id
    path_id=$(echo -n "$src_path" | md5sum | cut -d' ' -f1)
    
    # Remove any existing entry for this directory
    if [ -f "$PROGRESS_FILE" ]; then
        sed -i "/^$path_id:/d" "$PROGRESS_FILE"
    fi
    
    echo "$path_id:completed:$timestamp:$src_path" >> "$PROGRESS_FILE"
    log_success "Marked $(get_dir_display_name "$src_path") as completed"
}

# Mark a directory as in-progress
mark_in_progress() {
    local src_path="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local path_id
    path_id=$(echo -n "$src_path" | md5sum | cut -d' ' -f1)
    
    if [ -f "$PROGRESS_FILE" ]; then
        sed -i "/^$path_id:/d" "$PROGRESS_FILE"
    fi
    
    echo "$path_id:in-progress:$timestamp:$src_path" >> "$PROGRESS_FILE"
}

# Show migration status
show_status() {
    echo ""
    echo -e "${CYAN}=== NAS Migration Status ===${NC}"
    echo ""
    
    if [ ! -f "$PROGRESS_FILE" ]; then
        echo "No migration progress recorded yet."
        echo ""
        echo "Directories to migrate:"
        for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
            local src="${DIR_SOURCES[$i]}"
            local dest="${DIR_DESTINATIONS[$i]}"
            echo -e "  ${YELLOW}○${NC} [$i] $(get_dir_display_name "$src")"
            echo -e "       $src → $dest"
        done
    else
        echo "Progress file: $PROGRESS_FILE"
        echo ""
        for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
            local src="${DIR_SOURCES[$i]}"
            local dest="${DIR_DESTINATIONS[$i]}"
            local path_id
            path_id=$(echo -n "$src" | md5sum | cut -d' ' -f1)
            local status=$(grep "^$path_id:" "$PROGRESS_FILE" 2>/dev/null | cut -d: -f2)
            local timestamp=$(grep "^$path_id:" "$PROGRESS_FILE" 2>/dev/null | cut -d: -f3)
            
            case "$status" in
                "completed")
                    echo -e "  ${GREEN}✓${NC} [$i] $(get_dir_display_name "$src") (completed: $timestamp)"
                    echo -e "       $src → $dest"
                    ;;
                "in-progress")
                    echo -e "  ${YELLOW}◐${NC} [$i] $(get_dir_display_name "$src") (in progress since: $timestamp)"
                    echo -e "       $src → $dest"
                    ;;
                *)
                    echo -e "  ${RED}○${NC} [$i] $(get_dir_display_name "$src") (not started)"
                    echo -e "       $src → $dest"
                    ;;
            esac
        done
    fi
    
    echo ""
    
    # Show log files
    if [ -d "$LOG_DIR" ] && [ "$(ls -A "$LOG_DIR" 2>/dev/null)" ]; then
        echo "Recent log files:"
        ls -lt "$LOG_DIR" | head -5 | tail -4 | awk '{print "  " $NF}'
    fi
    
    echo ""
}

# Reset progress file
reset_progress() {
    if [ -f "$PROGRESS_FILE" ]; then
        rm "$PROGRESS_FILE"
        log_info "Progress file cleared."
    else
        log_info "No progress file to clear."
    fi
}

# Get human-readable size
get_dir_size() {
    local dir="$1"
    du -sh "$dir" 2>/dev/null | cut -f1 || echo "unknown"
}

# Migrate a single directory
migrate_directory() {
    local src_path="$1"
    local dest_path="$2"
    local display_name
    display_name=$(get_dir_display_name "$src_path")
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Migrating: $display_name"
    log_info "  Source: $src_path"
    log_info "  Dest:   $dest_path"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Verify source exists
    if [ ! -d "$src_path" ]; then
        log_error "Source directory does not exist: $src_path"
        return 1
    fi
    
    # Mark as in-progress
    if [ "$DRY_RUN" = false ]; then
        mark_in_progress "$src_path"
    fi
    
    # Build rsync command
    local rsync_opts=(
        --archive              # Preserve permissions, timestamps, etc.
        # Default comparison: size + modification time (--archive preserves times)
    )
    
    if [ "$SIZE_ONLY" = true ]; then
        rsync_opts+=(--size-only)  # Compare by file size only (faster)
    fi
    
    rsync_opts+=(
        --no-compress          # Skip compression (media files already compressed)
        --whole-file           # Copy whole files (faster on LAN than delta algorithm)
        --partial              # Keep partially transferred files
        --partial-dir=".rsync-partial"  # Store partial files in hidden dir
        --info=progress2       # Show overall progress
        --human-readable       # Human-readable sizes
        --stats                # Show transfer statistics
        --exclude=".rsync-partial"  # Don't sync partial directory
        --exclude="Thumbs.db"  # Exclude Windows thumbnail cache
        --exclude=".DS_Store"  # Exclude macOS metadata
        --exclude="desktop.ini" # Exclude Windows folder settings
    )

    if [ "$DRY_RUN" = true ]; then
        rsync_opts+=(--dry-run)
        log_info "DRY RUN - No files will be copied"
    fi
    
    log_info "Starting rsync..."
    log_info "Command: rsync ${rsync_opts[*]} \"$src_path/\" \"$dest_path/\""
    echo ""
    
    # Run rsync with real-time output
    if rsync "${rsync_opts[@]}" "$src_path/" "$dest_path/" 2>&1 | tee -a "$LOG_FILE"; then
        if [ "$DRY_RUN" = false ]; then
            mark_completed "$src_path"
        fi
        log_success "Completed: $display_name"
        return 0
    else
        local exit_code=$?
        log_error "rsync failed for $display_name with exit code $exit_code"
        return $exit_code
    fi
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
        --size-only)
            SIZE_ONLY=true
            shift
            ;;
        --resume)
            RESUME=true
            shift
            ;;
        --status)
            SHOW_STATUS=true
            shift
            ;;
        --reset)
            RESET_PROGRESS=true
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
                # Numeric index
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
                    echo "Use --status to see available directories"
                    exit 1
                fi
            fi
            shift
            ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Handle special modes
if [ "$SHOW_STATUS" = true ]; then
    show_status
    exit 0
fi

if [ "$RESET_PROGRESS" = true ]; then
    reset_progress
    exit 0
fi

# Use all directories if none specified
if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
    for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
        SELECTED_INDICES+=("$i")
    done
fi

# Start migration
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
printf "${CYAN}║${NC}          NAS Migration: %-17s → %-17s ${CYAN}║${NC}\n" "$SOURCE_NAME" "$DEST_NAME"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Log file: $LOG_FILE"
log_info "Progress file: $PROGRESS_FILE"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No files will be copied"
fi

if [ "$RESUME" = true ]; then
    log_info "RESUME MODE - Skipping completed directories"
fi

# Check that source directories exist
check_directory_paths

# Process directories
completed_count=0
skipped_count=0
failed_count=0

for idx in "${SELECTED_INDICES[@]}"; do
    src="${DIR_SOURCES[$idx]}"
    dest="${DIR_DESTINATIONS[$idx]}"
    
    # Skip if resuming and already completed
    if [ "$RESUME" = true ] && is_completed "$src"; then
        log_info "Skipping $(get_dir_display_name "$src") (already completed)"
        ((skipped_count++)) || true
        continue
    fi
    
    if migrate_directory "$src" "$dest"; then
        ((completed_count++)) || true
    else
        ((failed_count++)) || true
        log_error "Failed to migrate $(get_dir_display_name "$src")"
    fi
done

# Summary
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
log_info "Migration Summary:"
log_info "  Completed: $completed_count"
log_info "  Skipped:   $skipped_count"
log_info "  Failed:    $failed_count"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ $failed_count -gt 0 ]; then
    log_warning "Some directories failed. Check log file: $LOG_FILE"
    exit 1
fi

log_success "Migration complete!"