# NAS Migration Tools

A collection of bash scripts for migrating files between NAS devices over SMB/CIFS. Designed for large-scale migrations with resumable transfers, error recovery, and verification.

## Features

- **Resumable transfers** — Interrupt and resume without losing progress
- **Error recovery** — Automatically extracts and retries failed files
- **Verification** — Multiple verification methods (rsync dry-run, random sampling, checksums)
- **Configurable** — JSON configuration for flexible source/destination mapping
- **Progress tracking** — Logs and progress files for monitoring long migrations

## Quick Start

### 1. Install Dependencies

```bash
# Just works on Bluefin
# https://projectbluefin.io/

# Debian/Ubuntu
sudo apt install rsync jq cifs-utils

# Fedora/RHEL
sudo dnf install rsync jq cifs-utils
```

### 2. Configure

Copy the example config and customize:

```bash
cp config.example.json config.json
```

Edit `config.json` with your NAS details:

```json
{
  "source": {
    "name": "old-nas",
    "address": "192.168.0.100",
    "baseMountPath": "/var/mnt/old-nas",
    "credentialsFile": "~/.smbcredentials-old-nas",
    "mountOptions": "vers=2.0",
    "shares": [
      { "name": "Photos", "mountAs": "photos" },
      { "name": "Documents", "mountAs": "documents" }
    ]
  },
  "destination": {
    "name": "new-nas",
    "address": "192.168.0.200",
    "baseMountPath": "/var/mnt/new-nas",
    "credentialsFile": "~/.smbcredentials-new-nas",
    "mountOptions": "",
    "shares": [
      { "name": "photos", "mountAs": "photos" },
      { "name": "documents", "mountAs": "documents" }
    ]
  },
  "logDirectory": "~/nas-migrate-logs",
  "directories": [
    {
      "source": "/var/mnt/old-nas/photos",
      "destination": "/var/mnt/new-nas/photos"
    },
    {
      "source": "/var/mnt/old-nas/documents",
      "destination": "/var/mnt/new-nas/documents"
    },
    {
      "source": "/home/user/local-photos",
      "destination": "/var/mnt/new-nas/photos/local-imports"
    }
  ]
}
```

### 3. Set Up Credentials

Create credentials files for each NAS:

```bash
# ~/.smbcredentials-old-nas
username=your_username
password=your_password
domain=WORKGROUP
```

Secure the file:

```bash
chmod 600 ~/.smbcredentials-*
```

### 4. Mount NAS Shares

```bash
./mount-nas.sh
```

### 5. Run Migration

```bash
# Full pipeline (recommended)
./migrate-full.sh

# Or step by step
./migrate-files.sh --dry-run   # Preview
./migrate-files.sh             # Run migration
./verify-migration.sh             # Verify
```

## Scripts

| Script | Description |
|--------|-------------|
| `mount-nas.sh` | Mount/unmount NAS shares |
| `migrate-files.sh` | Main rsync migration (foreground) |
| `migrate-files-bg.sh` | Migration with background worker support |
| `migrate-full.sh` | Run complete pipeline automatically |
| `verify-migration.sh` | Verify migration with rsync + sampling |
| `checksum-verify.sh` | Deep checksum verification |
| `extract-rsync-errors.sh` | Extract errors from migration logs |
| `extract-errored-dirs.sh` | List directories with errors |
| `copy-errored-dirs.sh` | Retry copying failed files |

## Usage Examples

### Check Migration Status

```bash
./migrate-files.sh --status
```

### Resume Interrupted Migration

```bash
./migrate-files.sh --resume
```

### Migrate Specific Directories

```bash
./migrate-files.sh photos music
```

### Dry Run (Preview)

```bash
./migrate-files.sh --dry-run
```

### Verify with More Samples

```bash
./verify-migration.sh --sample 500
```

### Run Migration in Background

```bash
./migrate-files-bg.sh --start
./migrate-files-bg.sh --status   # Check progress
./migrate-files-bg.sh --stop     # Stop if needed
```

## Configuration Reference

### `config.json`

| Field | Description |
|-------|-------------|
| `source.name` | Friendly name for source NAS |
| `source.address` | IP or hostname |
| `source.baseMountPath` | Local mount point base path |
| `source.credentialsFile` | Path to SMB credentials file |
| `source.mountOptions` | Additional mount options (e.g., `vers=2.0`) |
| `source.shares` | Array of shares to mount (see below) |
| `destination.*` | Same fields for destination NAS |
| `logDirectory` | Directory for log files |
| `directories` | Array of directory mappings (see below) |

### Share Configuration

Each entry in `source.shares` or `destination.shares` defines an SMB share to mount:

```json
{
  "name": "Photos",     // SMB share name on the NAS
  "mountAs": "photos"   // Local directory name under baseMountPath
}
```

### Directory Mapping

Each entry in `directories` maps an absolute source path to an absolute destination:

```json
{
  "source": "/var/mnt/old-nas/photos",
  "destination": "/var/mnt/new-nas/photos"
}
```

**Features:**
- Paths can include subdirectories (e.g., `/var/mnt/new-nas/photos/local-imports`)
- Source can be a local path (e.g., `/home/user/photos`) for uploading to NAS
- Destination can be a local path for downloading from NAS
- Config validation prevents accidentally swapping source/destination paths

## Logs

Logs are stored in `~/nas-migrate-logs/` by default:

- `migrate-*.log` — Migration output
- `migrate-errors-*.log` — Extracted rsync errors
- `verify-*.log` — Verification results
- `checksum-verify-*.log` — Checksum verification results

## License

This is free and unencumbered software released into the public domain. See [LICENSE](LICENSE) for details.
