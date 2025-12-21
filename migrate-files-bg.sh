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
#   --resume      Skip directories marked as completed in progress file
#   --status      Show migration status and exit
#   --reset       Clear progress file and start fresh
#   --start       Start migration in background as a worker process
#   --stop        Stop the running worker process
#   --help        Show this help message
#
# Examples:
#   ./migrate-files.sh                    # Migrate all directories
#   ./migrate-files.sh music videos       # Migrate only music and videos
#   ./migrate-files.sh --dry-run          # Preview what would be copied
#   ./migrate-files.sh --resume           # Resume interrupted migration
#   ./migrate-files.sh --start            # Start migration in background
#   ./migrate-files.sh --status           # Check progress and worker status
#   ./migrate-files.sh --stop             # Stop background worker
# =============================================================================

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Script-specific configuration
PROGRESS_FILE="$HOME/.nas-migrate-progress"
PID_FILE="$HOME/.migrate-worker.pid"
WORKER_LOG="$LOG_DIR/migrate-worker.log"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/migrate-$TIMESTAMP.log"

# Flags
DRY_RUN=false
RESUME=false
SHOW_STATUS=false
RESET_PROGRESS=false
INTERRUPTED=false
WORKER_MODE=false
START_WORKER=false
STOP_WORKER=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 29 "$0" | tail -n 27
    exit 0
}

# Check if worker is running
is_worker_running() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            return 0
        else
            # Stale PID file
            rm -f "$PID_FILE"
            return 1
        fi
    fi
    return 1
}

# Start worker in background
start_worker() {
    if is_worker_running; then
        local pid=$(cat "$PID_FILE")
        log_error "Worker already running with PID $pid"
        log_info "Use --stop to stop the worker, or --status to check progress"
        exit 1
    fi
    
    log_info "Starting migration worker in background..."
    
    # Start worker process in background
    "$0" --worker "${SELECTED_DIRS[@]}" </dev/null >&/dev/null &
    local pid=$!
    
    echo "$pid" > "$PID_FILE"
    log_success "Worker started with PID $pid"
    log_info "Log file: $WORKER_LOG"
    log_info "Use --status to check progress"
    log_info "Use --stop to stop the worker"
}

# Stop worker
stop_worker() {
    if ! is_worker_running; then
        log_warning "No worker process is running"
        if [ -f "$PID_FILE" ]; then
            rm -f "$PID_FILE"
        fi
        exit 0
    fi
    
    local pid=$(cat "$PID_FILE")
    log_info "Stopping worker process (PID $pid)..."
    
    # Send SIGTERM for graceful shutdown
    if kill -TERM "$pid" 2>/dev/null; then
        log_info "Waiting for worker to finish current file..."
        
        # Wait up to 30 seconds for graceful shutdown
        local count=0
        while ps -p "$pid" > /dev/null 2>&1 && [ $count -lt 30 ]; do
            sleep 1
            ((count++))
        done
        
        if ps -p "$pid" > /dev/null 2>&1; then
            log_warning "Worker did not stop gracefully, forcing..."
            kill -KILL "$pid" 2>/dev/null || true
        fi
        
        log_success "Worker stopped"
    else
        log_warning "Could not signal worker process (may have already exited)"
    fi
    
    rm -f "$PID_FILE"
}

# Cleanup PID file on exit (for worker mode)
cleanup_on_exit() {
    if [ "$WORKER_MODE" = true ]; then
        rm -f "$PID_FILE"
    fi
}

# Signal handler for graceful interruption
handle_interrupt() {
    echo ""
    log_warning "Received interrupt signal (Ctrl+C)"
    log_info "Migration paused. Current transfer will stop after completing current file."
    log_info "Run with --resume to continue from where you left off."
    INTERRUPTED=true
    cleanup_on_exit
    exit 130
}

# Set up signal handlers
trap handle_interrupt SIGINT SIGTERM
trap cleanup_on_exit EXIT

# Check if a directory has been completed
is_completed() {
    local dir="$1"
    if [ -f "$PROGRESS_FILE" ]; then
        grep -q "^$dir:completed:" "$PROGRESS_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

# Mark a directory as completed
mark_completed() {
    local dir="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Remove any existing entry for this directory
    if [ -f "$PROGRESS_FILE" ]; then
        sed -i "/^$dir:/d" "$PROGRESS_FILE"
    fi
    
    echo "$dir:completed:$timestamp" >> "$PROGRESS_FILE"
    log_success "Marked $dir as completed"
}

# Mark a directory as in-progress
mark_in_progress() {
    local dir="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -f "$PROGRESS_FILE" ]; then
        sed -i "/^$dir:/d" "$PROGRESS_FILE"
    fi
    
    echo "$dir:in-progress:$timestamp" >> "$PROGRESS_FILE"
}

# Show migration status
show_status() {
    echo ""
    echo -e "${CYAN}=== NAS Migration Status ===${NC}"
    echo ""
    
    # Show worker status
    if is_worker_running; then
        local pid=$(cat "$PID_FILE")
        echo -e "${GREEN}Worker Status: Running (PID $pid)${NC}"
        if [ -f "$WORKER_LOG" ]; then
            echo "Worker Log: $WORKER_LOG"
        fi
    else
        echo -e "${YELLOW}Worker Status: Not running${NC}"
    fi
    echo ""
    
    if [ ! -f "$PROGRESS_FILE" ]; then
        echo "No migration progress recorded yet."
        echo ""
        echo "Directories to migrate:"
        for dir in "${DIR_ORDER[@]}"; do
            local dest="${DIR_MAP[$dir]}"
            echo -e "  ${YELLOW}○${NC} $dir → $dest (not started)"
        done
    else
        echo "Progress file: $PROGRESS_FILE"
        echo ""
        for dir in "${DIR_ORDER[@]}"; do
            local dest="${DIR_MAP[$dir]}"
            local status=$(grep "^$dir:" "$PROGRESS_FILE" 2>/dev/null | cut -d: -f2)
            local timestamp=$(grep "^$dir:" "$PROGRESS_FILE" 2>/dev/null | cut -d: -f3-)
            
            case "$status" in
                "completed")
                    echo -e "  ${GREEN}✓${NC} $dir → $dest (completed: $timestamp)"
                    ;;
                "in-progress")
                    echo -e "  ${YELLOW}◐${NC} $dir → $dest (in progress since: $timestamp)"
                    ;;
                *)
                    echo -e "  ${RED}○${NC} $dir → $dest (not started)"
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
    local src_name="$1"
    local dest_name="${DIR_MAP[$src_name]}"
    local src_path="$SOURCE_BASE/$src_name"
    local dest_path="$DEST_BASE/$dest_name"
    
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Migrating: $src_name → $dest_name"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Verify source exists
    if [ ! -d "$src_path" ]; then
        log_error "Source directory does not exist: $src_path"
        return 1
    fi
    
    # Show size estimate
    # Performance fix: du -sh is very slow on network mounts.
    # rsync --info=progress2 handles progress reporting efficiently.
    # log_info "Calculating source size..."
    # local src_size=$(get_dir_size "$src_path")
    # log_info "Source size: $src_size"
    
    # Mark as in-progress
    if [ "$DRY_RUN" = false ]; then
        mark_in_progress "$src_name"
    fi
    
    # Build rsync command
    local rsync_opts=(
        --archive              # Preserve permissions, timestamps, etc.
        --size-only            # Compare by file size (fast, ideal for initial migration)
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
            mark_completed "$src_name"
        fi
        log_success "Completed: $src_name → $dest_name"
        return 0
    else
        local exit_code=$?
        log_error "rsync failed for $src_name with exit code $exit_code"
        return $exit_code
    fi
}

# =============================================================================
# Main Script
# =============================================================================

# Parse command line arguments
SELECTED_DIRS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
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
        --start)
            START_WORKER=true
            shift
            ;;
        --stop)
            STOP_WORKER=true
            shift
            ;;
        --worker)
            WORKER_MODE=true
            RESUME=true  # Workers always resume
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
            # Assume it's a directory name
            if [[ -v "DIR_MAP[$1]" ]]; then
                SELECTED_DIRS+=("$1")
            else
                log_error "Unknown directory: $1"
                log_info "Valid directories: ${DIR_ORDER[*]}"
                exit 1
            fi
            shift
            ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Handle special modes
if [ "$START_WORKER" = true ]; then
    start_worker
    exit 0
fi

if [ "$STOP_WORKER" = true ]; then
    stop_worker
    exit 0
fi

if [ "$SHOW_STATUS" = true ]; then
    show_status
    exit 0
fi

if [ "$RESET_PROGRESS" = true ]; then
    reset_progress
    exit 0
fi

# Worker mode: redirect output to worker log
if [ "$WORKER_MODE" = true ]; then
    LOG_FILE="$WORKER_LOG"
    exec >> "$WORKER_LOG" 2>&1
    log_info "Worker mode started (PID $$)"
fi

# Use all directories if none specified
if [ ${#SELECTED_DIRS[@]} -eq 0 ]; then
    SELECTED_DIRS=("${DIR_ORDER[@]}")
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

# Check mounts
check_mounts_thorough

# Process directories
completed_count=0
skipped_count=0
failed_count=0

for dir in "${SELECTED_DIRS[@]}"; do
    # Skip if resuming and already completed
    if [ "$RESUME" = true ] && is_completed "$dir"; then
        log_info "Skipping $dir (already completed)"
        ((skipped_count++))
        continue
    fi
    
    if migrate_directory "$dir"; then
        ((completed_count++))
    else
        ((failed_count++))
        log_error "Failed to migrate $dir"
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