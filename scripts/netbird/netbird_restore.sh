#!/bin/bash
# =============================================================================
# netbird_restore.sh
# Restores a NetBird backup created by netbird_backup.sh from the restic
# repository, following https://docs.netbird.io/selfhosted/maintenance/backup
#
# Works on the original server or a fresh one (Docker + Compose installed,
# same domain pointing at it, TCP 80/443 + UDP 3478 open).
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
        error "This script must be run as root (sudo ./netbird_restore.sh)"
        exit 1
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/netbird-backup.cred"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

NETBIRD_DIR="${NETBIRD_DIR:-/opt/netbird}"
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-rclone:pCloud:/Backups/netbird}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/restic}"

# ── 1. Check Dependencies ─────────────────────────────────────────────────────
check_dependencies() {
    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        error "Docker with the compose plugin not found."
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
    restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots --tag netbird
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_dependencies

    echo "----------------------------------------------------------------------"
    echo "NetBird Restore Process (target: $NETBIRD_DIR)"

    list_snapshots

    echo ""
    read -rp "Enter Snapshot ID to restore (or 'latest'): " SNAPSHOT_ID
    SNAPSHOT_ID=${SNAPSHOT_ID:-latest}

    RESTORE_TMP=$(mktemp -d)
    trap 'rm -rf "$RESTORE_TMP"' EXIT

    step "Downloading snapshot from repository..."
    if ! restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" \
            restore "$SNAPSHOT_ID" --tag netbird --target "$RESTORE_TMP"; then
        error "Failed to restore snapshot from restic."
        exit 1
    fi

    # The staging dir was backed up with its absolute path
    COMPOSE_FILE=$(find "$RESTORE_TMP" -name docker-compose.yml -print -quit)
    if [[ -z "$COMPOSE_FILE" ]]; then
        error "No docker-compose.yml found in the restored data."
        exit 1
    fi
    SRC=$(dirname "$COMPOSE_FILE")

    if [[ ! -d "$SRC/netbird" ]]; then
        error "No NetBird data directory (netbird/) found in the restored data."
        exit 1
    fi

    MGMT_SERVICE=$(cat "$SRC/.mgmt_service" 2>/dev/null || echo "netbird-server")
    info "Restored backup contents:"
    ls -la "$SRC"

    warn "CRITICAL: This will OVERWRITE the NetBird config in $NETBIRD_DIR"
    warn "and all data in the $MGMT_SERVICE container (peers, policies, keys)."
    read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
        info "Restore cancelled."
        exit 0
    fi

    mkdir -p "$NETBIRD_DIR"
    cd "$NETBIRD_DIR"

    if [[ -f docker-compose.yml ]]; then
        step "Stopping running NetBird services..."
        docker compose down
    fi

    step "Restoring configuration files..."
    find "$SRC" -maxdepth 1 -type f ! -name .mgmt_service -exec cp -a {} "$NETBIRD_DIR/" \;
    if [[ -d "$SRC/crowdsec" ]]; then
        rm -rf "$NETBIRD_DIR/crowdsec"
        cp -a "$SRC/crowdsec" "$NETBIRD_DIR/crowdsec"
    fi
    success "Configuration restored."

    step "Restoring NetBird data into $MGMT_SERVICE..."
    docker compose create "$MGMT_SERVICE"
    docker compose cp -a "$SRC/netbird/." "$MGMT_SERVICE:/var/lib/netbird/"
    success "NetBird data restored."

    if [[ -d "$SRC/crowdsec_db" ]]; then
        step "Restoring CrowdSec data..."
        docker compose create crowdsec
        docker compose cp -a "$SRC/crowdsec_db/." crowdsec:/var/lib/crowdsec/data/
    fi

    if [[ -d "$SRC/proxy_certs" ]]; then
        step "Restoring proxy certificates..."
        docker compose create proxy
        docker compose cp -a "$SRC/proxy_certs/." proxy:/certs/
    fi

    if [[ -d "$SRC/traefik_letsencrypt" ]]; then
        step "Restoring Traefik Let's Encrypt data..."
        docker compose create traefik
        docker compose cp -a "$SRC/traefik_letsencrypt/." traefik:/letsencrypt/
    fi

    step "Starting NetBird..."
    docker compose up -d
    success "NetBird restore completed."
    info "Open the dashboard and verify peers, policies and setup keys."
}

main "$@"
