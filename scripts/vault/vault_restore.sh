#!/bin/bash
# =============================================================================
# vault_restore.sh
# Restores a Vault Raft snapshot from the restic repository.
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./vault_restore.sh)"
        exit 1
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/vault-backup.cred"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

export VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
export VAULT_TOKEN=${VAULT_TOKEN:-""}

# S3 repository on the SeaweedFS. /etc/vault-backup.cred (sourced above) may set S3_ENDPOINT,
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (keys of the S3 identity "vault").
# Snapshots from before the move to S3 are in rclone:pCloud:/Backups/vault_pb (set RESTIC_REPOSITORY to use it).
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-s3:${S3_ENDPOINT:-http://docker01.vpn.rjst.de:8333}/vault/raft}"
RESTIC_PASSWORD_FILE="/root/restic"

# ── 1. Check Dependencies ─────────────────────────────────────────────────────
check_dependencies() {
    if ! command -v vault >/dev/null 2>&1; then
        error "Vault CLI not found."
        exit 1
    fi
    if ! command -v restic >/dev/null 2>&1; then
        error "Restic not found. Cannot perform restore."
        exit 1
    fi
}

# ── 2. List Snapshots ─────────────────────────────────────────────────────────
list_snapshots() {
    step "Available snapshots in remote repository"
    restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_dependencies

    echo "----------------------------------------------------------------------"
    echo "Vault Restore Process"

    # Load and display snapshots
    list_snapshots

    echo ""
    read -rp "Enter Snapshot ID to restore (or 'latest'): " SNAPSHOT_ID
    SNAPSHOT_ID=${SNAPSHOT_ID:-latest}

    # Create temporary directory for restoration
    RESTORE_TMP=$(mktemp -d)
    trap 'rm -rf "$RESTORE_TMP"' EXIT

    step "Downloading snapshot from repository..."
    if ! restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" restore "$SNAPSHOT_ID" --target "$RESTORE_TMP"; then
        error "Failed to restore snapshot from restic."
        exit 1
    fi

    # Locate the .snap file
    # The snapshot was backed up with its absolute path
    SNAP_FILE=$(find "$RESTORE_TMP" -name "*.snap" | head -n 1)

    if [[ -z "$SNAP_FILE" ]]; then
        error "No snapshot file (.snap) found in the restored data."
        exit 1
    fi

    info "Found snapshot file: $(basename "$SNAP_FILE")"

    # Confirm before proceeding
    warn "CRITICAL: Restoring a snapshot will OVERWRITE all current Vault data."
    warn "Vault must be unsealed to perform this operation."
    read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        info "Restore cancelled."
        exit 0
    fi

    step "Performing Vault Raft restore..."
    if vault operator raft snapshot restore "$SNAP_FILE"; then
        success "Vault restore completed successfully."
        info "Note: You might need to check Vault's status and unseal it if necessary."
    else
        error "Vault restore failed."
        exit 1
    fi
}

main "$@"
