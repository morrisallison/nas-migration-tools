#!/bin/bash

# =============================================================================
# Mount NAS Script
# =============================================================================
# Mounts shares from source and/or destination NAS defined in config.json
#
# Usage:
#   ./mount-nas.sh [OPTIONS]
#
# Options:
#   --target <source|destination|both>  Which NAS to mount (default: both)
#   --dry-run                           Show what would be done without mounting
#   --unmount                           Unmount instead of mount
#   --help                              Show this help message
#
# Examples:
#   ./mount-nas.sh                      # Mount both NAS
#   ./mount-nas.sh --target source      # Mount only source NAS
#   ./mount-nas.sh --target destination # Mount only destination NAS
#   ./mount-nas.sh --unmount            # Unmount both NAS
# =============================================================================

set -euo pipefail

# Source shared library for config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Default options
target="both"
dry_run=false
unmount=false

# Show help
show_help() {
    head -n 22 "$0" | tail -n 19
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            target="$2"
            if [[ ! "$target" =~ ^(source|destination|both)$ ]]; then
                echo "Error: --target must be 'source', 'destination', or 'both'"
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            dry_run=true
            echo "DRY RUN MODE: No changes will be made"
            shift
            ;;
        --unmount)
            unmount=true
            echo "UNMOUNT MODE: Unmounting directories"
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--target <source|destination|both>] [--dry-run] [--unmount]"
            exit 1
            ;;
    esac
done

# Mount or unmount a single share
# Arguments: nas_address, base_mount_path, mount_opts, share_name, mount_as
process_share() {
    local nas_address="$1"
    local base_mount_path="$2"
    local mount_opts="$3"
    local share_name="$4"
    local mount_as="$5"
    
    local mount_point="$base_mount_path/$mount_as"

    if [ "$unmount" = true ]; then
        # Check if already mounted before attempting unmount
        if ! mountpoint -q "$mount_point"; then
            echo "  $mount_point is not mounted, skipping"
            return 0
        fi

        echo "  Unmounting $mount_point"

        if [ "$dry_run" = false ]; then
            sudo umount "$mount_point" || { echo "Error: Failed to unmount $mount_point"; return 1; }
        fi
    else
        echo "  Creating directory: $mount_point"
        if [ "$dry_run" = false ]; then
            sudo mkdir -p "$mount_point" || { echo "Error: Failed to create directory $mount_point"; return 1; }
        fi

        # Check if already mounted
        if mountpoint -q "$mount_point"; then
            echo "  $mount_point is already mounted"
            return 0
        fi

        echo "  Mounting //$nas_address/$share_name to $mount_point"
        if [ "$dry_run" = false ]; then
            sudo mount -t cifs -o "$mount_opts" "//$nas_address/$share_name" "$mount_point" || { echo "Error: Failed to mount $share_name"; return 1; }
        fi
    fi
}

# Mount/unmount all shares for a NAS
# Arguments: "source" or "destination"
process_nas() {
    local nas_type="$1"
    local nas_address nas_name base_mount_path creds_file mount_opts_extra
    local -a shares_name=()
    local -a shares_mount_as=()
    
    if [ "$nas_type" = "source" ]; then
        nas_name="$SOURCE_NAME"
        nas_address="$SOURCE_ADDRESS"
        base_mount_path="$SOURCE_BASE"
        creds_file="$SOURCE_CREDS"
        mount_opts_extra="$SOURCE_MOUNT_OPTS"
        shares_name=("${SOURCE_SHARES_NAME[@]}")
        shares_mount_as=("${SOURCE_SHARES_MOUNT_AS[@]}")
    else
        nas_name="$DEST_NAME"
        nas_address="$DEST_ADDRESS"
        base_mount_path="$DEST_BASE"
        creds_file="$DEST_CREDS"
        mount_opts_extra="$DEST_MOUNT_OPTS"
        shares_name=("${DEST_SHARES_NAME[@]}")
        shares_mount_as=("${DEST_SHARES_MOUNT_AS[@]}")
    fi
    
    # Check if there are any shares to process
    if [ ${#shares_name[@]} -eq 0 ]; then
        echo "  No shares configured for $nas_type NAS"
        return 0
    fi
    
    local action="Mounting"
    [ "$unmount" = true ] && action="Unmounting"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$action $nas_type NAS: $nas_name ($nas_address)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if credentials file exists
    if [ ! -f "$creds_file" ]; then
        echo "Error: Credentials file not found at $creds_file"
        return 1
    fi
    
    # Check if NAS is reachable (only for mounting)
    if [ "$unmount" = false ]; then
        if ! ping -c 1 -W 2 "$nas_address" &> /dev/null; then
            echo "Warning: NAS at $nas_address is not reachable"
        fi
    fi
    
    # Build mount options string
    local mount_opts="credentials=$creds_file,uid=$UID,gid=$(id -g),file_mode=0664,dir_mode=0775"
    if [ -n "$mount_opts_extra" ]; then
        mount_opts="$mount_opts,$mount_opts_extra"
    fi
    
    # Process each share
    local errors=0
    for ((i=0; i<${#shares_name[@]}; i++)); do
        if ! process_share "$nas_address" "$base_mount_path" "$mount_opts" "${shares_name[$i]}" "${shares_mount_as[$i]}"; then
            ((errors++))
        fi
    done
    
    if [ $errors -gt 0 ]; then
        echo "Completed with $errors error(s)"
        return 1
    fi
    
    echo "All $nas_type shares processed successfully"
    return 0
}

# Main
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    NAS Mount Utility                         ║"
echo "╚══════════════════════════════════════════════════════════════╝"

errors=0

if [ "$target" = "source" ] || [ "$target" = "both" ]; then
    if ! process_nas "source"; then
        ((errors++))
    fi
fi

if [ "$target" = "destination" ] || [ "$target" = "both" ]; then
    if ! process_nas "destination"; then
        ((errors++))
    fi
fi

echo ""
if [ $errors -gt 0 ]; then
    echo "Completed with errors"
    exit 1
fi

echo "All operations completed successfully."
