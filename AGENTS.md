# AGENTS.md - AI Agent Guidelines for NAS Migration Tools

This document provides guidance for AI agents working with this codebase.

## Project Overview

This is a **bash-based NAS migration toolkit** for copying files between SMB/CIFS network-attached storage devices. The project is designed for large-scale, resumable file migrations with error recovery and verification capabilities.

**Primary language:** Bash (with a minor TypeScript utility)  
**Target platform:** Linux (tested on Fedora/Bluefin)  
**Dependencies:** `rsync`, `jq`, `cifs-utils`

## Architecture

### Core Components

| File | Purpose |
|------|---------|
| `lib/migrate-common.sh` | Shared library with config loading, logging, and utility functions |
| `config.json` | User configuration (NAS addresses, credentials, directory mappings) |

### Script Categories

**Migration:**
- `migrate-files.sh` — Main foreground migration using rsync
- `migrate-files-bg.sh` — Background worker variant with --start/--stop/--status
- `migrate-full.sh` — Orchestrates the complete pipeline (migrate → extract errors → retry → verify)

**Mounting:**
- `mount-nas.sh` — Mount/unmount SMB shares from source and destination NAS

**Verification:**
- `verify-migration.sh` — Rsync dry-run comparison + random file sampling
- `checksum-verify.sh` — Deep checksum verification (md5/sha1/sha256)

**Error Recovery:**
- `extract-rsync-errors.sh` — Parse rsync errors from migration logs
- `extract-errored-dirs.sh` — Extract directory paths that failed
- `copy-errored-dirs.sh` — Retry failed files using `cp -n`

## Code Conventions

### Bash Style

- All scripts use `set -euo pipefail` for strict error handling
- Scripts source `lib/migrate-common.sh` for shared functionality
- Header comments include usage, options, and examples (extracted via `head/tail` for --help)
- Use `show_help()` function that extracts header comments
- Logging uses colored output: `log_info`, `log_success`, `log_warning`, `log_error`

### Configuration

- Config is JSON-based (`config.json`) and parsed with `jq`
- Paths support `~` expansion via `expand_path()` function
- Shares are mounted independently from directory mappings
- Directory mappings use absolute paths for flexibility

### Common Patterns

```bash
# Script setup
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/migrate-common.sh"

# Config is auto-loaded when migrate-common.sh is sourced
# Available vars: SOURCE_BASE, DEST_BASE, DIR_SOURCES[], DIR_DESTINATIONS[], etc.

# Standard option parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) show_help ;;
        *) # handle positional args
    esac
done
```

## Key Variables (from migrate-common.sh)

After sourcing the common library, these are available:

| Variable | Type | Description |
|----------|------|-------------|
| `SOURCE_BASE` | string | Mount path for source NAS (e.g., `/var/mnt/old-nas`) |
| `DEST_BASE` | string | Mount path for destination NAS |
| `SOURCE_NAME` / `DEST_NAME` | string | Friendly names for logging |
| `SOURCE_SHARES_NAME` | array | SMB share names for source NAS |
| `SOURCE_SHARES_MOUNT_AS` | array | Mount point names for source shares |
| `DEST_SHARES_NAME` | array | SMB share names for destination NAS |
| `DEST_SHARES_MOUNT_AS` | array | Mount point names for destination shares |
| `DIR_SOURCES` | array | Ordered list of source directory absolute paths |
| `DIR_DESTINATIONS` | array | Ordered list of destination directory absolute paths |
| `DIR_MAP` | assoc array | Maps source path → destination path |
| `REVERSE_MAP` | assoc array | Maps destination path → source path |
| `LOG_DIR` | string | Directory for log files |

## Making Changes

### Adding a New Script

1. Create script with standard header (usage, options, examples)
2. Add `set -euo pipefail` and source the common library
3. Implement `show_help()` that extracts header comments
4. Use logging functions instead of raw `echo`
5. Support `--dry-run` and `--help` flags
6. Update README.md scripts table

### Modifying Configuration

- Edit `config.example.json` for new config options
- Update `load_config()` in `lib/migrate-common.sh` to parse new fields
- Document new fields in README.md configuration reference

### Adding Error Handling

- Scripts should gracefully handle missing mounts (use `check_mounts()`)
- Support interruption with signal handlers (`trap handle_interrupt SIGINT SIGTERM`)
- Progress should be resumable where possible

## Testing Changes

1. Always use `--dry-run` first to preview changes
2. Test mounting with `./mount-nas.sh --dry-run`
3. Test migration with `./migrate-files.sh --dry-run [directory]`
4. Check logs in `~/nas-migrate-logs/`

## File Locations

| Path | Purpose |
|------|---------|
| `~/nas-migrate-logs/` | All log files (migrate, verify, checksum) |
| `~/.nas-migrate-progress` | Progress tracking for resume capability |
| `~/.migrate-worker.pid` | PID file for background worker |
| `~/.smbcredentials-*` | SMB credential files (user-created) |

## Common Tasks

### "Add a new verification method"
→ Create new script following `verify-migration.sh` pattern, source common library, add to `migrate-full.sh` pipeline if appropriate.

### "Add a new config option"
→ Update `config.example.json`, modify `load_config()` in `lib/migrate-common.sh`, use new variable in relevant scripts.

### "Improve error recovery"
→ Modify `extract-rsync-errors.sh` or `extract-errored-dirs.sh` to handle new error patterns, update `copy-errored-dirs.sh` for new retry strategies.

### "Add parallel processing"
→ Look at `checksum-verify.sh` for an example using `--parallel` flag with controlled job spawning.

## Gotchas

- **Shares vs directories:** Shares are mounted independently via `source.shares`/`destination.shares`. Directory mappings in `directories[]` use absolute paths and are separate from share configuration.
- **Path validation:** Config validation prevents swapping source/destination paths (e.g., source path under destination mount path).
- **Path expansion:** Always use `expand_path()` for paths from config that may contain `~`.
- **Dry run consistency:** All destructive operations should check `$DRY_RUN` flag.
- **Mount state:** Scripts assume NAS is already mounted. Use `check_mounts()` or `check_directory_paths()` to verify.
- **Rsync options:** Optimized for LAN transfers with `--size-only`, `--whole-file`, no compression. Don't add `--checksum` by default (slow for large migrations).
- **Local paths supported:** Directory mappings can include local paths (not just NAS mounts) for flexible migration scenarios.
