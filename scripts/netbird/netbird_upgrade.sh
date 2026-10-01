#!/bin/bash
# =============================================================================
# netbird_upgrade.sh
# Upgrades a self-hosted NetBird (docker compose) installation, following
# https://docs.netbird.io/selfhosted/maintenance/upgrade
#
#   1. pulls the new images (running containers are not touched yet)
#   2. exits if nothing changed
#   3. creates a rollback point: old images are tagged netbird-rollback/<svc>:<ts>,
#      a full backup is made with netbird_backup.sh (restic, tag pre-upgrade)
#      and its data is kept locally in $BACKUP_DIR/rollback/<ts>
#   4. recreates the containers with the new images
#   5. health check - on failure offers (or with --auto-rollback runs)
#      netbird_rollback.sh
#
# Usage: sudo ./netbird_upgrade.sh [--yes] [--auto-rollback] [--keep N]
#
# Optional in /etc/netbird-backup.cred:
#   NETBIRD_DIR, BACKUP_DIR,
#   HEALTH_URL (e.g. https://netbird.example.com - must answer with HTTP 2xx/3xx)
#   HEALTH_TIMEOUT (seconds, default 120), ROLLBACK_KEEP (default 3)
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
        error "This script must be run as root (sudo ./netbird_upgrade.sh)"
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
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-120}"
ROLLBACK_KEEP="${ROLLBACK_KEEP:-3}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ASSUME_YES=false
AUTO_ROLLBACK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        ASSUME_YES=true; shift ;;
        --auto-rollback) AUTO_ROLLBACK=true; shift ;;
        --keep)          ROLLBACK_KEEP="$2"; shift 2 ;;
        -h|--help)       sed -n '16p' "$0" | sed 's/^# //'; exit 0 ;;
        *)               error "Unknown argument: $1"; exit 1 ;;
    esac
done

find_script() {
    if [[ -x "$SCRIPT_DIR/$1" ]]; then echo "$SCRIPT_DIR/$1"
    elif command -v "$1" >/dev/null 2>&1; then command -v "$1"
    else error "$1 not found (next to this script or in PATH)."; exit 1
    fi
}

confirm() {
    $ASSUME_YES && return 0
    read -rp "$1 [y/N]: " answer
    [[ "$answer" =~ ^[yY]$ ]]
}

# Human readable version of an image: OCI version label, else short image ID
image_version() {
    local v
    v=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null || true)
    [[ -n "$v" && "$v" != "<no value>" ]] && echo "$v" || echo "${1#sha256:}" | cut -c1-12
}

# ── 1. Detect services ────────────────────────────────────────────────────────
detect_services() {
    step "Detecting NetBird services in $NETBIRD_DIR"

    [[ -f "$NETBIRD_DIR/docker-compose.yml" ]] || { error "No docker-compose.yml in $NETBIRD_DIR"; exit 1; }
    cd "$NETBIRD_DIR"

    local all candidates
    all=$(docker compose config --services)
    if grep -qx netbird-server <<< "$all"; then
        candidates=(netbird-server dashboard proxy)
    else
        warn "Legacy setup (separate containers) detected."
        candidates=(management dashboard signal relay)
    fi

    SERVICES=()
    for svc in "${candidates[@]}"; do
        grep -qx "$svc" <<< "$all" && SERVICES+=("$svc")
    done

    declare -gA OLD_ID REF
    for svc in "${SERVICES[@]}"; do
        local cid
        cid=$(docker compose ps -aq "$svc")
        [[ -n "$cid" ]] || { error "No container for service '$svc' - is NetBird running?"; exit 1; }
        OLD_ID[$svc]=$(docker inspect -f '{{.Image}}' "$cid")
        REF[$svc]=$(docker inspect -f '{{.Config.Image}}' "$cid")
    done
    success "Services: ${SERVICES[*]}"
}

# ── 2. Pull + compare ─────────────────────────────────────────────────────────
pull_images() {
    step "Pulling new images"
    docker compose pull "${SERVICES[@]}"

    declare -gA NEW_ID
    CHANGED=false
    printf "\n  %-16s %-22s %-22s\n" "SERVICE" "CURRENT" "NEW"
    for svc in "${SERVICES[@]}"; do
        NEW_ID[$svc]=$(docker image inspect -f '{{.Id}}' "${REF[$svc]}")
        local mark=""
        if [[ "${NEW_ID[$svc]}" != "${OLD_ID[$svc]}" ]]; then
            CHANGED=true
            mark=" *"
        fi
        printf "  %-16s %-22s %-22s%s\n" "$svc" \
            "$(image_version "${OLD_ID[$svc]}")" "$(image_version "${NEW_ID[$svc]}")" "$mark"
    done
    echo ""

    if ! $CHANGED; then
        success "NetBird is already up to date - nothing to do."
        exit 0
    fi

    info "Check the release notes for breaking changes / config migrations:"
    info "  https://github.com/netbirdio/netbird/releases"
    info "  https://github.com/netbirdio/dashboard/releases"
}

# ── 3. Rollback point ─────────────────────────────────────────────────────────
create_rollback_point() {
    TS=$(date +%Y%m%d-%H%M%S)
    ROLLBACK_POINT="$BACKUP_DIR/rollback/$TS"

    step "Creating rollback point $ROLLBACK_POINT"
    mkdir -p "$BACKUP_DIR/rollback"
    chmod 700 "$BACKUP_DIR" "$BACKUP_DIR/rollback"

    # Tag old images so they survive 'docker image prune'
    for svc in "${SERVICES[@]}"; do
        docker tag "${OLD_ID[$svc]}" "netbird-rollback/$svc:$TS"
    done

    # Full backup (stops NetBird briefly, uploads to restic, keeps data locally)
    if ! KEEP_STAGING_DIR="$ROLLBACK_POINT/data" EXTRA_TAG="pre-upgrade" "$(find_script netbird_backup.sh)"; then
        error "Pre-upgrade backup failed - aborting upgrade. Nothing was changed."
        for svc in "${SERVICES[@]}"; do docker rmi "netbird-rollback/$svc:$TS" >/dev/null || true; done
        rm -rf "$ROLLBACK_POINT"
        exit 1
    fi

    for svc in "${SERVICES[@]}"; do
        printf '%s\t%s\t%s\n' "$svc" "${REF[$svc]}" "${OLD_ID[$svc]}"
    done > "$ROLLBACK_POINT/images.tsv"
    success "Rollback point created."
}

# ── 4. Upgrade ────────────────────────────────────────────────────────────────
upgrade() {
    step "Recreating containers with new images"
    docker compose up -d --force-recreate "${SERVICES[@]}"
}

# ── 5. Health check ───────────────────────────────────────────────────────────
services_healthy() {
    for svc in "${SERVICES[@]}"; do
        local cid state
        cid=$(docker compose ps -aq "$svc")
        [[ -n "$cid" ]] || return 1
        state=$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid")
        read -r status restarts health <<< "$state"
        [[ "$status" == "running" && "$restarts" == "0" ]] || return 1
        [[ "$health" == "healthy" || "$health" == "none" ]] || return 1
    done
    if [[ -n "$HEALTH_URL" ]]; then
        curl -fsS -o /dev/null --max-time 10 "$HEALTH_URL" || return 1
    fi
}

health_check() {
    step "Health check (up to ${HEALTH_TIMEOUT}s)"
    local waited=0 stable=0
    # Services have to look healthy for 30s in a row (catches crash loops)
    while (( waited < HEALTH_TIMEOUT )); do
        sleep 5; waited=$((waited + 5))
        if services_healthy; then
            stable=$((stable + 5))
            (( stable >= 30 )) && { success "All services healthy."; return 0; }
        else
            stable=0
        fi
    done
    error "Services not healthy after ${HEALTH_TIMEOUT}s:"
    docker compose ps "${SERVICES[@]}" || true
    docker compose logs --tail 30 "${SERVICES[0]}" || true
    return 1
}

# ── Cleanup old rollback points ───────────────────────────────────────────────
prune_rollback_points() {
    local points
    mapfile -t points < <(ls -1d "$BACKUP_DIR"/rollback/*/ 2>/dev/null | sort -r | tail -n +$((ROLLBACK_KEEP + 1)))
    for p in "${points[@]}"; do
        local ts
        ts=$(basename "$p")
        info "Removing old rollback point $ts"
        docker images --format '{{.Repository}}:{{.Tag}}' | grep "^netbird-rollback/.*:$ts$" \
            | xargs -r docker rmi >/dev/null || true
        rm -rf "$p"
    done
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_root

    echo "----------------------------------------------------------------------"
    echo "NetBird Upgrade"

    detect_services
    pull_images

    confirm "Upgrade now? NetBird will be stopped briefly for the backup and restarted twice." \
        || { info "Upgrade cancelled."; exit 0; }

    create_rollback_point
    upgrade

    if health_check; then
        prune_rollback_points
        success "NetBird upgrade completed. Rollback point: $TS"
        info "Roll back with: netbird_rollback.sh $TS"
        exit 0
    fi

    if $AUTO_ROLLBACK || confirm "Roll back to $TS now?"; then
        "$(find_script netbird_rollback.sh)" --yes "$TS"
    else
        warn "No rollback done. Run later with: netbird_rollback.sh $TS"
        exit 1
    fi
}

main "$@"
