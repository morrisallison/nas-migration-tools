#!/bin/bash

# =============================================================================
# NAS Migration - Full Pipeline
# =============================================================================
# Runs the complete NAS migration pipeline:
#   1. migrate-files.sh      - Initial rsync migration
#   2. extract-rsync-errors  - Extract errors from migration log
#   3. extract-errored-dirs  - Get list of directories with errors
#   4. copy-errored-dirs     - Retry copying errored files
#   5. verify-migration      - Verify with rsync dry-run
#   6. checksum-verify       - Verify checksums on flagged files
#
# Usage:
#   ./migrate-full.sh [OPTIONS]
#
# Options:
#   --dry-run     Pass --dry-run to all scripts (preview mode)
#   --skip-confirm Skip confirmation prompt
#   --help        Show this help message
#
# Examples:
#   ./migrate-full.sh                # Run full migration pipeline
#   ./migrate-full.sh --dry-run      # Preview what would be done
# =============================================================================

set -euo pipefail

# Source shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Flags
DRY_RUN=false
SKIP_CONFIRM=false

# =============================================================================
# Functions
# =============================================================================

show_help() {
    head -n 23 "$0" | tail -n 21
    exit 0
}

# Run a script with error handling
# Arguments: description, script_path, [args...]
run_step() {
    local step_num="$1"
    local description="$2"
    local script="$3"
    shift 3
    local args=("$@")
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Step $step_num: $description${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    log_info "Running: $script ${args[*]}"
    echo ""
    
    if ! "$SCRIPT_DIR/$script" "${args[@]}"; then
        local exit_code=$?
        echo ""
        log_error "Step $step_num failed with exit code $exit_code"
        log_error "Pipeline stopped. Please resolve the issue and re-run."
        exit $exit_code
    fi
    
    echo ""
    log_success "Step $step_num completed successfully"
}

# Show configuration summary
show_config() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              NAS Migration - Configuration                   ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BLUE}Source NAS:${NC}"
    echo "  Name:        $SOURCE_NAME"
    echo "  Address:     $SOURCE_ADDRESS"
    echo "  Mount Path:  $SOURCE_BASE"
    echo ""
    
    echo -e "${BLUE}Destination NAS:${NC}"
    echo "  Name:        $DEST_NAME"
    echo "  Address:     $DEST_ADDRESS"
    echo "  Mount Path:  $DEST_BASE"
    echo ""
    
    echo -e "${BLUE}Directories to migrate:${NC}"
    for dir in "${DIR_ORDER[@]}"; do
        local dest="${DIR_MAP[$dir]}"
        if [ "$dir" = "$dest" ]; then
            echo "  • $dir"
        else
            echo "  • $dir → $dest"
        fi
    done
    echo ""
    
    echo -e "${BLUE}Log Directory:${NC} $LOG_DIR"
    echo -e "${BLUE}Progress File:${NC} $PROGRESS_FILE"
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Mode: DRY RUN (no changes will be made)${NC}"
        echo ""
    fi
}

# Show pipeline steps
show_pipeline() {
    echo -e "${BLUE}Pipeline Steps:${NC}"
    echo "  1. migrate-files.sh        - Initial rsync migration"
    echo "  2. extract-rsync-errors.sh - Extract errors from migration log"
    echo "  3. extract-errored-dirs.sh - Get list of directories with errors"
    echo "  4. copy-errored-dirs.sh    - Retry copying errored files"
    echo "  5. verify-migration.sh     - Verify with rsync dry-run"
    echo "  6. checksum-verify.sh      - Verify checksums on flagged files"
    echo ""
}

# Prompt for confirmation
confirm_continue() {
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi
    
    echo -e "${YELLOW}This will start the full migration pipeline.${NC}"
    echo ""
    read -p "Continue? [y/N] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Migration cancelled by user."
        exit 0
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
        --skip-confirm)
            SKIP_CONFIRM=true
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
            log_error "Unexpected argument: $1"
            show_help
            ;;
    esac
done

# Create log directory
mkdir -p "$LOG_DIR"

# Show configuration and get confirmation
show_config
show_pipeline
confirm_continue

# Build common args
DRY_RUN_ARG=""
if [ "$DRY_RUN" = true ]; then
    DRY_RUN_ARG="--dry-run"
fi

# Start pipeline
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Starting Migration Pipeline                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"

START_TIME=$(date +%s)

# Step 1: Initial migration
if [ "$DRY_RUN" = true ]; then
    run_step 1 "Initial Migration (rsync)" "migrate-files.sh" --dry-run
else
    run_step 1 "Initial Migration (rsync)" "migrate-files.sh" --resume
fi

# Step 2: Extract rsync errors from the latest migration log
run_step 2 "Extract rsync Errors" "extract-rsync-errors.sh" --latest $DRY_RUN_ARG

# Step 3: Extract errored directories
run_step 3 "Extract Errored Directories" "extract-errored-dirs.sh" --latest $DRY_RUN_ARG

# Step 4: Copy errored files
run_step 4 "Copy Errored Files" "copy-errored-dirs.sh" $DRY_RUN_ARG

# Step 5: Verify migration
run_step 5 "Verify Migration" "verify-migration.sh" $DRY_RUN_ARG

# Step 6: Checksum verification
run_step 6 "Checksum Verification" "checksum-verify.sh" --latest $DRY_RUN_ARG

# Calculate elapsed time
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

# Final summary
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Migration Pipeline Complete                     ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_success "All steps completed successfully!"
log_info "Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_info "This was a DRY RUN. No actual changes were made."
    log_info "Run without --dry-run to perform the actual migration."
else
    log_info "Migration logs are in: $LOG_DIR"
    log_info "Review the logs to ensure everything completed correctly."
fi

echo ""
