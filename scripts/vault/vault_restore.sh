#!/bin/bash
# =============================================================================
# vault_restore.sh
# Restores a Vault Raft snapshot from the restic repository.
#
#   sudo scripts/vault/vault_restore.sh [--force]
#
#   --force   restore into a Vault with other unseal keys (a freshly initialised Vault after a total
#             loss). Vault then skips its check of the snapshot's hash file, and afterwards it is sealed
#             with the unseal keys of the backed-up Vault. Not needed to roll back the same Vault
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

# S3 repository on the RustFS. /etc/vault-backup.cred (sourced above) may set S3_ENDPOINT,
# AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (keys of the S3 identity "vault").
# Snapshots from before the move to S3 are in rclone:pCloud:/Backups/vault_pb (set RESTIC_REPOSITORY to use it).
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-s3:${S3_ENDPOINT:-http://docker01.server.lan:9000}/vault/raft}"
# Password of the vault repository, set RESTIC_PASSWORD_FILE if it is not in /root/restic (that file is used by NetBird)
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/restic}"

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

usage() {
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2
}

# Extra arguments of "vault operator raft snapshot restore", set by --force
RESTORE_FLAGS=()

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)   RESTORE_FLAGS=(-force); shift ;;
            -h|--help) usage; exit 0 ;;
            *)         error "Unknown argument: $1"; usage; exit 2 ;;
        esac
    done
}

# ── 2. List Snapshots ─────────────────────────────────────────────────────────
list_snapshots() {
    step "Available snapshots in remote repository"
    restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    parse_arguments "$@"
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
    if [[ ${#RESTORE_FLAGS[@]} -gt 0 ]]; then
        warn "--force: the hash check is skipped; afterwards Vault opens only with the unseal keys of the backed-up Vault."
    fi
    read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        info "Restore cancelled."
        exit 0
    fi

    step "Performing Vault Raft restore..."
    if vault operator raft snapshot restore "${RESTORE_FLAGS[@]}" "$SNAP_FILE"; then
        success "Vault restore completed successfully."
        info "Note: You might need to check Vault's status and unseal it if necessary."
    else
        error "Vault restore failed. A snapshot of a Vault with other unseal keys needs --force."
        exit 1
    fi
}

main "$@"
