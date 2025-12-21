#!/bin/bash

# =============================================================================
# Common Library for NAS Migration Scripts
# =============================================================================
# Shared configuration and functions used across all migration scripts.
# Source this file at the beginning of each script:
#   source "$(dirname "$0")/lib/migrate-common.sh"
#
# Configuration is loaded from config.json in the script directory.
# Override with: CONFIG_FILE=/path/to/config.json ./script.sh
# =============================================================================

# Determine script directory (where the library is located)
MIGRATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT_DIR="$(dirname "$MIGRATE_LIB_DIR")"

# Default config file location (can be overridden via environment)
CONFIG_FILE="${CONFIG_FILE:-$MIGRATE_SCRIPT_DIR/config.json}"

# Colors for output (defined early for error messages)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# Dependency Check Functions
# =============================================================================

# Check if jq is available
require_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}[ERROR]${NC} jq is required but not installed."
        echo ""
        echo "Install jq using your package manager:"
        echo "  Fedora/RHEL: sudo dnf install jq"
        echo "  Ubuntu/Debian: sudo apt install jq"
        echo "  macOS: brew install jq"
        exit 1
    fi
}

# =============================================================================
# String Utility Functions
# =============================================================================

# Convert string to kebab-case (lowercase with hyphens)
# Usage: kebab=$(to_kebab_case "My String")
to_kebab_case() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/ /-/g'
}

# Expand ~ to $HOME in paths
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# =============================================================================
# Configuration Loading
# =============================================================================

# Load configuration from JSON file
# Populates: SOURCE_BASE, DEST_BASE, SOURCE_NAME, DEST_NAME, LOG_DIR, 
#            PROGRESS_FILE, DIR_ORDER, DIR_MAP, REVERSE_MAP,
#            SOURCE_ADDRESS, DEST_ADDRESS, SOURCE_CREDS, DEST_CREDS,
#            SHARE_NAMES_SOURCE, SHARE_NAMES_DEST,
#            SOURCE_MOUNT_OPTS, DEST_MOUNT_OPTS, DEST_EXTRA_SHARES
load_config() {
    # Check dependencies
    require_jq
    
    # Check config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} Config file not found: $CONFIG_FILE"
        echo ""
        echo "Create a config.json file or set CONFIG_FILE environment variable."
        echo "See config.example.json for the expected format."
        exit 1
    fi
    
    # Load source NAS config
    SOURCE_NAME=$(jq -r '.source.name' "$CONFIG_FILE")
    SOURCE_ADDRESS=$(jq -r '.source.address' "$CONFIG_FILE")
    SOURCE_BASE=$(expand_path "$(jq -r '.source.basePath' "$CONFIG_FILE")")
    SOURCE_CREDS=$(expand_path "$(jq -r '.source.credentialsFile' "$CONFIG_FILE")")
    SOURCE_MOUNT_OPTS=$(jq -r '.source.mountOptions // ""' "$CONFIG_FILE")
    
    # Load destination NAS config
    DEST_NAME=$(jq -r '.destination.name' "$CONFIG_FILE")
    DEST_ADDRESS=$(jq -r '.destination.address' "$CONFIG_FILE")
    DEST_BASE=$(expand_path "$(jq -r '.destination.basePath' "$CONFIG_FILE")")
    DEST_CREDS=$(expand_path "$(jq -r '.destination.credentialsFile' "$CONFIG_FILE")")
    DEST_MOUNT_OPTS=$(jq -r '.destination.mountOptions // ""' "$CONFIG_FILE")
    
    # Load extra shares (destination-only directories not part of migration)
    mapfile -t DEST_EXTRA_SHARES < <(jq -r '.destination.extraShares // [] | .[]' "$CONFIG_FILE")
    
    # Load paths
    LOG_DIR=$(expand_path "$(jq -r '.logDir' "$CONFIG_FILE")")
    PROGRESS_FILE=$(expand_path "$(jq -r '.progressFile' "$CONFIG_FILE")")
    
    # Load directory order (source directory names)
    mapfile -t DIR_ORDER < <(jq -r '.directories[].source' "$CONFIG_FILE")
    
    # Build associative arrays for directory mapping
    declare -gA DIR_MAP
    declare -gA REVERSE_MAP
    declare -gA SHARE_NAMES_SOURCE
    declare -gA SHARE_NAMES_DEST
    
    while IFS=$'\t' read -r src dest shareSrc shareDest; do
        DIR_MAP["$src"]="$dest"
        REVERSE_MAP["$dest"]="$src"
        SHARE_NAMES_SOURCE["$src"]="$shareSrc"
        SHARE_NAMES_DEST["$dest"]="$shareDest"
    done < <(jq -r '.directories[] | [.source, .destination, .shareNameSource, .shareNameDest] | @tsv' "$CONFIG_FILE")
}

# Load config immediately when library is sourced
load_config

# =============================================================================
# Logging Functions
# =============================================================================

# Base log function - writes to stdout and optionally to a log file
# Usage: log "message"
# Set LOG_FILE before calling to enable file logging
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    if [ -n "${LOG_FILE:-}" ]; then
        echo -e "$message" | tee -a "$LOG_FILE"
    else
        echo -e "$message"
    fi
}

log_info() {
    log "${BLUE}[INFO]${NC} $1"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    log "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

log_fail() {
    log "${RED}[FAIL]${NC} $1"
}

log_pass() {
    log "${GREEN}[PASS]${NC} $1"
}

# =============================================================================
# Mount Check Functions
# =============================================================================

# Check if both NAS mounts are accessible
# Usage: check_mounts
check_mounts() {
    local errors=0

    log_info "Checking NAS mount points..."

    if [ ! -d "$SOURCE_BASE" ] || [ -z "$(ls -A "$SOURCE_BASE" 2>/dev/null)" ]; then
        log_error "Source NAS ($SOURCE_NAME) not mounted at $SOURCE_BASE"
        log_info "Run: $MIGRATE_SCRIPT_DIR/mount-nas.sh --target source"
        ((errors++))
    fi

    if [ ! -d "$DEST_BASE" ] || [ -z "$(ls -A "$DEST_BASE" 2>/dev/null)" ]; then
        log_error "Destination NAS ($DEST_NAME) not mounted at $DEST_BASE"
        log_info "Run: $MIGRATE_SCRIPT_DIR/mount-nas.sh --target destination"
        ((errors++))
    fi

    if [ $errors -gt 0 ]; then
        log_error "Please mount the NAS shares before running this script."
        return 1
    fi

    log_success "Both NAS mount points are accessible."
    return 0
}

# More thorough mount check that looks for subdirectories
# Used by migrate scripts that need to be more careful
check_mounts_thorough() {
    local errors=0

    log_info "Checking NAS mount points..."

    if ! mountpoint -q "$SOURCE_BASE" 2>/dev/null && [ ! -d "$SOURCE_BASE/${DIR_ORDER[0]}" ]; then
        # Check if any subdirectory is mounted
        local source_mounted=false
        for dir in "${DIR_ORDER[@]}"; do
            if [ -d "$SOURCE_BASE/$dir" ] && [ "$(ls -A "$SOURCE_BASE/$dir" 2>/dev/null)" ]; then
                source_mounted=true
                break
            fi
        done
        if [ "$source_mounted" = false ]; then
            log_error "Source NAS ($SOURCE_NAME) not mounted at $SOURCE_BASE"
            log_info "Run: $MIGRATE_SCRIPT_DIR/mount-nas.sh --target source"
            ((errors++))
        fi
    fi

    if ! mountpoint -q "$DEST_BASE" 2>/dev/null && [ ! -d "$DEST_BASE/${DIR_MAP[${DIR_ORDER[0]}]}" ]; then
        # Check if any subdirectory is mounted
        local dest_mounted=false
        for dir in "${DIR_MAP[@]}"; do
            if [ -d "$DEST_BASE/$dir" ]; then
                dest_mounted=true
                break
            fi
        done
        if [ "$dest_mounted" = false ]; then
            log_error "Destination NAS ($DEST_NAME) not mounted at $DEST_BASE"
            log_info "Run: $MIGRATE_SCRIPT_DIR/mount-nas.sh --target destination"
            ((errors++))
        fi
    fi

    if [ $errors -gt 0 ]; then
        log_error "Please mount the NAS shares before running migration."
        return 1
    fi

    log_success "Both NAS mount points are accessible."
    return 0
}

# =============================================================================
# Path Mapping Functions
# =============================================================================

# Map destination path back to source path
# Uses REVERSE_MAP to translate directory names dynamically
# Usage: source_path=$(map_dest_to_source "projects/foo")
map_dest_to_source() {
    local path="$1"
    local dest_dir="${path%%/*}"
    local rest="${path#*/}"
    
    # If no slash, the whole path is the directory
    if [ "$dest_dir" = "$path" ]; then
        rest=""
    fi
    
    # Look up source directory from reverse map
    local src_dir="${REVERSE_MAP[$dest_dir]:-$dest_dir}"
    
    if [ -n "$rest" ]; then
        echo "$src_dir/$rest"
    else
        echo "$src_dir"
    fi
}

# Map source path to destination path
# Uses DIR_MAP to translate directory names dynamically
# Usage: dest_path=$(map_source_to_dest "storage/foo")
map_source_to_dest() {
    local path="$1"
    local src_dir="${path%%/*}"
    local rest="${path#*/}"
    
    # If no slash, the whole path is the directory
    if [ "$src_dir" = "$path" ]; then
        rest=""
    fi
    
    # Look up destination directory from map
    local dest_dir="${DIR_MAP[$src_dir]:-$src_dir}"
    
    if [ -n "$rest" ]; then
        echo "$dest_dir/$rest"
    else
        echo "$dest_dir"
    fi
}

# =============================================================================
# Utility Functions
# =============================================================================

# Create log directory if it doesn't exist
ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

# Generate a timestamp string for log files
# Usage: ts=$(get_timestamp)
get_timestamp() {
    date +"%Y%m%d-%H%M%S"
}

# Print a section header
# Usage: print_header "My Script Name"
print_header() {
    local title="$1"
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    printf "║ %-62s ║\n" "$title"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Print a section divider
print_divider() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Print divider without color (for logging)
log_divider() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
