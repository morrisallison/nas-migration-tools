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

# Expand ~ to $HOME in paths
expand_path() {
    local path="$1"
    echo "${path/#\~/$HOME}"
}

# =============================================================================
# Configuration Loading
# =============================================================================

# Configuration variables populated by load_config()
SOURCE_NAME=""
SOURCE_ADDRESS=""
SOURCE_CREDS=""
SOURCE_BASE=""
SOURCE_MOUNT_OPTS=""
DEST_NAME=""
DEST_ADDRESS=""
DEST_CREDS=""
DEST_BASE=""
DEST_MOUNT_OPTS=""
LOG_DIR=""

# Arrays for shares (parallel arrays: NAME[i] corresponds to MOUNT_AS[i])
declare -a SOURCE_SHARES_NAME=()
declare -a SOURCE_SHARES_MOUNT_AS=()
declare -a DEST_SHARES_NAME=()
declare -a DEST_SHARES_MOUNT_AS=()

# Arrays for directory mappings (absolute paths)
declare -a DIR_SOURCES=()
declare -a DIR_DESTINATIONS=()

# Associative arrays for quick lookups
declare -gA DIR_MAP        # source path -> destination path
declare -gA REVERSE_MAP    # destination path -> source path

# Load configuration from JSON file
# Populates: SOURCE_BASE, DEST_BASE, SOURCE_NAME, DEST_NAME, LOG_DIR,
#            SOURCE_SHARES_*, DEST_SHARES_*, DIR_SOURCES, DIR_DESTINATIONS,
#            DIR_MAP, REVERSE_MAP
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
    
    # Validate JSON syntax
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} Invalid JSON in config file: $CONFIG_FILE"
        exit 1
    fi
    
    # Load source NAS config
    SOURCE_NAME=$(jq -r '.source.name // "Source NAS"' "$CONFIG_FILE")
    SOURCE_ADDRESS=$(jq -r '.source.address // ""' "$CONFIG_FILE")
    SOURCE_BASE=$(expand_path "$(jq -r '.source.baseMountPath // ""' "$CONFIG_FILE")")
    SOURCE_CREDS=$(expand_path "$(jq -r '.source.credentialsFile // ""' "$CONFIG_FILE")")
    SOURCE_MOUNT_OPTS=$(jq -r '.source.mountOptions // ""' "$CONFIG_FILE")
    
    # Load destination NAS config
    DEST_NAME=$(jq -r '.destination.name // "Destination NAS"' "$CONFIG_FILE")
    DEST_ADDRESS=$(jq -r '.destination.address // ""' "$CONFIG_FILE")
    DEST_BASE=$(expand_path "$(jq -r '.destination.baseMountPath // ""' "$CONFIG_FILE")")
    DEST_CREDS=$(expand_path "$(jq -r '.destination.credentialsFile // ""' "$CONFIG_FILE")")
    DEST_MOUNT_OPTS=$(jq -r '.destination.mountOptions // ""' "$CONFIG_FILE")
    
    # Load log directory
    LOG_DIR=$(expand_path "$(jq -r '.logDirectory // "~/nas-migrate-logs"' "$CONFIG_FILE")")
    
    # Parse source shares
    local share_count
    share_count=$(jq '.source.shares // [] | length' "$CONFIG_FILE")
    for ((i=0; i<share_count; i++)); do
        SOURCE_SHARES_NAME+=("$(jq -r ".source.shares[$i].name" "$CONFIG_FILE")")
        SOURCE_SHARES_MOUNT_AS+=("$(jq -r ".source.shares[$i].mountAs" "$CONFIG_FILE")")
    done
    
    # Parse destination shares
    share_count=$(jq '.destination.shares // [] | length' "$CONFIG_FILE")
    for ((i=0; i<share_count; i++)); do
        DEST_SHARES_NAME+=("$(jq -r ".destination.shares[$i].name" "$CONFIG_FILE")")
        DEST_SHARES_MOUNT_AS+=("$(jq -r ".destination.shares[$i].mountAs" "$CONFIG_FILE")")
    done
    
    # Parse directory mappings (absolute paths)
    local dir_count
    dir_count=$(jq '.directories | length' "$CONFIG_FILE")
    for ((i=0; i<dir_count; i++)); do
        local src_path dest_path
        src_path=$(expand_path "$(jq -r ".directories[$i].source" "$CONFIG_FILE")")
        dest_path=$(expand_path "$(jq -r ".directories[$i].destination" "$CONFIG_FILE")")
        
        DIR_SOURCES+=("$src_path")
        DIR_DESTINATIONS+=("$dest_path")
        DIR_MAP["$src_path"]="$dest_path"
        REVERSE_MAP["$dest_path"]="$src_path"
    done
    
    # Validate configuration
    validate_directory_paths
}

# Validate directory paths to prevent dangerous misconfigurations
validate_directory_paths() {
    local errors=0
    
    for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
        local src="${DIR_SOURCES[$i]}"
        local dest="${DIR_DESTINATIONS[$i]}"
        
        # Check: source path must not be under destination base mount path
        # Use trailing slash to ensure proper directory containment check
        if [[ -n "$DEST_BASE" && "$src" == "$DEST_BASE/"* ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid config: directories[$i].source ('$src') is under destination.baseMountPath ('$DEST_BASE')"
            ((errors++))
        fi
        
        # Check: destination path must not be under source base mount path
        if [[ -n "$SOURCE_BASE" && "$dest" == "$SOURCE_BASE/"* ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid config: directories[$i].destination ('$dest') is under source.baseMountPath ('$SOURCE_BASE')"
            ((errors++))
        fi
        
        # Check: source and destination must not be the same
        if [[ "$src" == "$dest" ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid config: directories[$i] has identical source and destination ('$src')"
            ((errors++))
        fi
        
        # Check: destination must not be a parent of source (would cause recursion)
        if [[ "$src" == "$dest"/* ]]; then
            echo -e "${RED}[ERROR]${NC} Invalid config: directories[$i].source ('$src') is inside destination ('$dest')"
            ((errors++))
        fi
    done
    
    if [ $errors -gt 0 ]; then
        echo -e "${RED}[ERROR]${NC} Configuration validation failed with $errors error(s)"
        exit 1
    fi
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

# Check if NAS shares are mounted
# Arguments: "source", "destination", or "both" (default)
check_mounts() {
    local check_type="${1:-both}"
    local errors=0

    log_info "Checking NAS mount points..."

    if [[ "$check_type" == "source" || "$check_type" == "both" ]]; then
        for mount_as in "${SOURCE_SHARES_MOUNT_AS[@]}"; do
            local mount_point="$SOURCE_BASE/$mount_as"
            if ! mountpoint -q "$mount_point" 2>/dev/null; then
                log_error "Source share not mounted: $mount_point"
                ((errors++))
            fi
        done
    fi

    if [[ "$check_type" == "destination" || "$check_type" == "both" ]]; then
        for mount_as in "${DEST_SHARES_MOUNT_AS[@]}"; do
            local mount_point="$DEST_BASE/$mount_as"
            if ! mountpoint -q "$mount_point" 2>/dev/null; then
                log_error "Destination share not mounted: $mount_point"
                ((errors++))
            fi
        done
    fi

    if [ $errors -gt 0 ]; then
        log_error "Missing $errors mount(s). Run ./mount-nas.sh first."
        return 1
    fi

    log_success "All required NAS shares are mounted."
    return 0
}

# Check if directory paths exist (for migration scripts)
# This validates that the actual source directories in the config exist
check_directory_paths() {
    local errors=0

    log_info "Checking directory paths..."

    for ((i=0; i<${#DIR_SOURCES[@]}; i++)); do
        local src="${DIR_SOURCES[$i]}"
        if [ ! -d "$src" ]; then
            log_error "Source directory does not exist: $src"
            ((errors++))
        fi
    done

    if [ $errors -gt 0 ]; then
        log_error "Some source directories are missing. Check mounts and config."
        return 1
    fi

    log_success "All source directories are accessible."
    return 0
}

# =============================================================================
# Path Mapping Functions
# =============================================================================

# Get destination path for a given source path
# Handles both exact matches and subpaths
# Usage: dest_path=$(get_dest_for_source "/var/mnt/old-nas/docs/subdir")
get_dest_for_source() {
    local path="$1"
    
    # Try exact match first
    if [[ -v DIR_MAP["$path"] ]]; then
        echo "${DIR_MAP[$path]}"
        return 0
    fi
    
    # Try to find a parent directory match
    for src in "${DIR_SOURCES[@]}"; do
        if [[ "$path" == "$src"/* ]]; then
            local relative="${path#$src/}"
            echo "${DIR_MAP[$src]}/$relative"
            return 0
        fi
    done
    
    return 1
}

# Get source path for a given destination path
# Handles both exact matches and subpaths
# Usage: src_path=$(get_source_for_dest "/var/mnt/new-nas/docs/subdir")
get_source_for_dest() {
    local path="$1"
    
    # Try exact match first
    if [[ -v REVERSE_MAP["$path"] ]]; then
        echo "${REVERSE_MAP[$path]}"
        return 0
    fi
    
    # Try to find a parent directory match
    for dest in "${DIR_DESTINATIONS[@]}"; do
        if [[ "$path" == "$dest"/* ]]; then
            local relative="${path#$dest/}"
            echo "${REVERSE_MAP[$dest]}/$relative"
            return 0
        fi
    done
    
    return 1
}

# Get display name for a source path (last component or meaningful name)
# Usage: name=$(get_dir_display_name "/var/mnt/old-nas/documents")
get_dir_display_name() {
    local path="$1"
    basename "$path"
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
