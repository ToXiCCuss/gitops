#!/bin/bash
# =============================================================================
# netbird_rollback.sh
# Rolls NetBird back to a rollback point created by netbird_upgrade.sh:
#   - re-tags the old images (netbird-rollback/<svc>:<ts>) to the image
#     references used in docker-compose.yml
#   - restores the config files and /var/lib/netbird from the local copy of
#     the pre-upgrade backup (database migrations of the new version are undone)
#   - recreates the containers
#
# Everything changed in NetBird after the upgrade (new peers, policies, ...)
# is lost. Rollback points are local only - for older states or a new server
# use netbird_restore.sh (restic).
#
# Usage: sudo ./netbird_rollback.sh [--yes] [<timestamp>|latest]
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
        error "This script must be run as root (sudo ./netbird_rollback.sh)"
        exit 1
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
CONFIG_FILE="/etc/netbird-backup.cred"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

NETBIRD_DIR="${NETBIRD_DIR:-/opt/netbird}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/netbird}"
ROLLBACK_DIR="$BACKUP_DIR/rollback"

ASSUME_YES=false
POINT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)  ASSUME_YES=true; shift ;;
        -h|--help) sed -n '15p' "$0" | sed 's/^# //'; exit 0 ;;
        *)         POINT="$1"; shift ;;
    esac
done

# ── 1. Select rollback point ──────────────────────────────────────────────────
select_point() {
    local points
    mapfile -t points < <(ls -1 "$ROLLBACK_DIR" 2>/dev/null | sort -r)
    if [[ ${#points[@]} -eq 0 ]]; then
        error "No rollback points in $ROLLBACK_DIR."
        info  "Use netbird_restore.sh to restore from restic instead."
        exit 1
    fi

    if [[ -z "$POINT" ]]; then
        step "Available rollback points"
        for p in "${points[@]}"; do
            echo "  $p"
            while IFS=$'\t' read -r svc ref _; do
                printf "      %-16s %s\n" "$svc" "$ref"
            done < "$ROLLBACK_DIR/$p/images.tsv" 2>/dev/null || true
        done
        echo ""
        if $ASSUME_YES; then
            POINT="latest"
        else
            read -rp "Rollback point to restore (or 'latest'): " POINT
            POINT=${POINT:-latest}
        fi
    fi
    [[ "$POINT" == "latest" ]] && POINT="${points[0]}"

    RP="$ROLLBACK_DIR/$POINT"
    if [[ ! -f "$RP/images.tsv" || ! -d "$RP/data/netbird" ]]; then
        error "Rollback point '$POINT' is incomplete or does not exist ($RP)."
        exit 1
    fi
    MGMT_SERVICE=$(cat "$RP/data/.mgmt_service" 2>/dev/null || echo "netbird-server")
    info "Using rollback point $POINT"
}

# ── 2. Check images ───────────────────────────────────────────────────────────
check_images() {
    step "Checking rollback images"
    SERVICES=()
    while IFS=$'\t' read -r svc ref old_id; do
        if ! docker image inspect "netbird-rollback/$svc:$POINT" >/dev/null 2>&1; then
            error "Image netbird-rollback/$svc:$POINT is missing (pruned?)."
            exit 1
        fi
        if [[ "$ref" == *@* ]]; then
            error "Service $svc uses a digest reference ($ref) - cannot re-tag, roll back manually."
            exit 1
        fi
        SERVICES+=("$svc")
    done < "$RP/images.tsv"
    success "Images present for: ${SERVICES[*]}"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_root

    echo "----------------------------------------------------------------------"
    echo "NetBird Rollback"

    [[ -d "$NETBIRD_DIR" ]] || { error "$NETBIRD_DIR does not exist."; exit 1; }
    cd "$NETBIRD_DIR"

    select_point
    check_images

    warn "CRITICAL: This restores NetBird to the state of $POINT."
    warn "All changes made in NetBird since then (peers, policies, users) are LOST."
    if ! $ASSUME_YES; then
        read -rp "Are you sure you want to proceed? [y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
            info "Rollback cancelled."
            exit 0
        fi
    fi

    step "Stopping NetBird..."
    docker compose stop

    step "Restoring configuration files..."
    find "$RP/data" -maxdepth 1 -type f ! -name .mgmt_service -exec cp -a {} "$NETBIRD_DIR/" \;
    success "Configuration restored."

    step "Restoring old images..."
    while IFS=$'\t' read -r svc ref _; do
        docker tag "netbird-rollback/$svc:$POINT" "$ref"
        success "$ref -> netbird-rollback/$svc:$POINT"
    done < "$RP/images.tsv"

    step "Restoring NetBird data into $MGMT_SERVICE..."
    local cid src
    cid=$(docker compose ps -aq "$MGMT_SERVICE")
    src=""
    if [[ -n "$cid" ]]; then
        src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/netbird"}}{{.Source}}{{end}}{{end}}' "$cid")
    fi
    if [[ -n "$src" && -d "$src" ]]; then
        # Wipe first: leftover files of the new version (e.g. SQLite WAL) must not survive
        find "$src" -mindepth 1 -delete
        cp -a "$RP/data/netbird/." "$src/"
        success "Data restored into $src"
    else
        warn "Could not determine the volume path, falling back to 'docker compose cp'."
        docker compose create "$MGMT_SERVICE"
        docker compose cp -a "$RP/data/netbird/." "$MGMT_SERVICE:/var/lib/netbird/"
    fi

    step "Starting NetBird with the old images..."
    docker compose up -d --force-recreate "${SERVICES[@]}"
    docker compose up -d

    docker compose ps
    success "Rollback to $POINT completed."
    warn "'docker compose pull' will fetch the new version again - pin the image"
    warn "versions in docker-compose.yml if you want to stay on this version."
}

main "$@"
