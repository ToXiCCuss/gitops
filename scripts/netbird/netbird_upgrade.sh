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
#   4. recreates the containers with the new images (NetBird first, then
#      CrowdSec and Traefik one at a time with --no-deps)
#   5. health check - on failure offers (or with --auto-rollback runs)
#      netbird_rollback.sh
#
# Traefik and CrowdSec are not part of the NetBird release, their versions are
# set in docker-compose.yml. --traefik, --crowdsec and --bouncer (the plugin
# version, --experimental.plugins.bouncer.version in the traefik command) change
# them: the new docker-compose.yml is prepared as a copy, used for the pull and
# only written after the backup, so netbird_rollback.sh restores the old one.
# --traefik v3.7.12 or newer also sets aliasHeadersStrategy=delete on the web and
# websecure entrypoints.
#
# Usage: sudo ./netbird_upgrade.sh [--yes] [--auto-rollback] [--keep N] [--traefik TAG] [--crowdsec TAG] [--bouncer VERSION]
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
EDGE_SERVICE_NAMES=(crowdsec traefik)
COMPOSE_FILE_NAME="docker-compose.yml"
UPGRADE_COMPOSE_NAME="docker-compose.upgrade.yml"
VERSION_PATTERN='^[A-Za-z0-9._-]+$'

ASSUME_YES=false
AUTO_ROLLBACK=false
declare -A NEW_TAG
NEW_BOUNCER_VERSION=""
UPGRADE_COMPOSE=""
PULL_COMPOSE_FILE="$COMPOSE_FILE_NAME"

require_version() {
    if [[ ! "$2" =~ $VERSION_PATTERN ]]; then
        error "$1 needs a version like v3.7.14, got '$2'"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        ASSUME_YES=true; shift ;;
        --auto-rollback) AUTO_ROLLBACK=true; shift ;;
        --keep)          ROLLBACK_KEEP="$2"; shift 2 ;;
        --traefik)       require_version "$1" "${2:-}"; NEW_TAG[traefik]="$2"; shift 2 ;;
        --crowdsec)      require_version "$1" "${2:-}"; NEW_TAG[crowdsec]="$2"; shift 2 ;;
        --bouncer)       require_version "$1" "${2:-}"; NEW_BOUNCER_VERSION="$2"; shift 2 ;;
        -h|--help)       sed -n '25p' "$0" | sed 's/^# //'; exit 0 ;;
        *)               error "Unknown argument: $1"; exit 1 ;;
    esac
done

trap 'rm -f "$UPGRADE_COMPOSE"' EXIT

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

    NETBIRD_SERVICES=()
    EDGE_SERVICES=()
    for svc in "${candidates[@]}"; do
        grep -qx "$svc" <<< "$all" && NETBIRD_SERVICES+=("$svc")
    done
    # CrowdSec before Traefik: the bouncer plugin in Traefik talks to CrowdSec
    for svc in "${EDGE_SERVICE_NAMES[@]}"; do
        grep -qx "$svc" <<< "$all" && EDGE_SERVICES+=("$svc")
    done
    SERVICES=("${NETBIRD_SERVICES[@]}" "${EDGE_SERVICES[@]}")

    declare -gA OLD_ID REF TARGET_REF
    for svc in "${SERVICES[@]}"; do
        local cid
        cid=$(docker compose ps -aq "$svc")
        [[ -n "$cid" ]] || { error "No container for service '$svc' - is NetBird running?"; exit 1; }
        OLD_ID[$svc]=$(docker inspect -f '{{.Image}}' "$cid")
        REF[$svc]=$(docker inspect -f '{{.Config.Image}}' "$cid")
        TARGET_REF[$svc]="${REF[$svc]}"
    done
    success "Services: ${SERVICES[*]}"
}

# ── New docker-compose.yml (only with --traefik/--crowdsec/--bouncer) ─────────
# Image reference with the tag replaced; digest and untagged references are refused
retag_reference() {
    local reference="$1" tag="$2"
    if [[ "$reference" == *@* || "${reference##*/}" != *:* ]]; then
        error "Cannot change the tag of '$reference' (digest or untagged) - edit docker-compose.yml by hand."
        exit 1
    fi
    echo "${reference%:*}:$tag"
}

# Sets image: of one service (2-space indented key under services:) in a compose file
set_image_reference() {
    local service="$1" reference="$2" file="$3" content
    content=$(awk -v service="$service" -v reference="$reference" '
        /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { current = $1; sub(/:$/, "", current) }
        current == service && !done && /^[[:space:]]+image:[[:space:]]/ { sub(/image:.*/, "image: " reference); done = 1 }
        { print }
        END { exit done ? 0 : 1 }' "$file") \
        || { error "No 'image:' line found for service '$service' in $COMPOSE_FILE_NAME."; exit 1; }
    printf '%s\n' "$content" > "$file"
}

set_bouncer_version() {
    local version="$1" file="$2"
    if ! grep -q 'experimental\.plugins\.bouncer\.version=' "$file"; then
        error "No --experimental.plugins.bouncer.version flag in $COMPOSE_FILE_NAME - cannot set --bouncer."
        exit 1
    fi
    sed -i -E "s/(experimental\.plugins\.bouncer\.version=)[^\"' ]+/\1$version/" "$file"
}

# True when version $1 is at least $2 (sort -V)
is_version_at_least() {
    [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# Traefik 3.7.12 fixes header-alias spoofing, but only with aliasHeadersStrategy=delete on the
# entrypoints (default is keep). Older versions do not start with the flag.
set_alias_headers_strategy() {
    local file="$1" content
    if grep -q 'underscoreHeadersStrategy' "$file"; then
        error "$COMPOSE_FILE_NAME has underscoreHeadersStrategy flags - replace them with aliasHeadersStrategy by hand."
        exit 1
    fi
    if ! grep -q 'aliasHeadersStrategy' "$file"; then
        content=$(awk '
            { print }
            /entrypoints\.(web|websecure)\.address=/ {
                line = $0
                sub(/\.address=[^"\047[:space:]]*/, ".http.aliasHeadersStrategy=delete", line)
                print line
                added++
            }
            END { exit added == 2 ? 0 : 1 }' "$file") \
            || { error "Expected one --entrypoints.web.address and one --entrypoints.websecure.address line in $COMPOSE_FILE_NAME."; exit 1; }
        printf '%s\n' "$content" > "$file"
    fi
}

# Traefik silently falls back to another network when the flag does not match the Compose network
check_traefik_network() {
    local configured actual
    if [[ -n "${REF[traefik]:-}" ]]; then
        configured=$(docker compose config | grep -oP $'providers\\.docker\\.network=\\K[^"\'\\s]+' | head -n1 || true)
        actual=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
            "$(docker compose ps -aq traefik)")
        if [[ -n "$configured" ]] && ! grep -qx "$configured" <<< "$actual"; then
            warn "Traefik has --providers.docker.network=$configured, but its networks are: $(tr '\n' ' ' <<< "$actual")"
            warn "Set the flag to the real network name in $COMPOSE_FILE_NAME (see NetBird upgrade docs)."
        fi
    fi
}

prepare_compose_changes() {
    if [[ ${#NEW_TAG[@]} -gt 0 || -n "$NEW_BOUNCER_VERSION" ]]; then
        step "Preparing $COMPOSE_FILE_NAME changes"
        UPGRADE_COMPOSE="$NETBIRD_DIR/$UPGRADE_COMPOSE_NAME"
        cp -a "$COMPOSE_FILE_NAME" "$UPGRADE_COMPOSE"

        for svc in "${!NEW_TAG[@]}"; do
            [[ -n "${REF[$svc]:-}" ]] || { error "Service '$svc' is not in $COMPOSE_FILE_NAME."; exit 1; }
            TARGET_REF[$svc]=$(retag_reference "${REF[$svc]}" "${NEW_TAG[$svc]}")
            set_image_reference "$svc" "${TARGET_REF[$svc]}" "$UPGRADE_COMPOSE"
        done
        if [[ -n "${NEW_TAG[traefik]:-}" ]]; then
            if is_version_at_least "${NEW_TAG[traefik]}" "v3.7.12"; then
                set_alias_headers_strategy "$UPGRADE_COMPOSE"
            else
                warn "Traefik ${NEW_TAG[traefik]} is older than v3.7.12 (header-alias spoofing, GHSA-rf44-j88r-hh8c)."
            fi
        fi
        [[ -z "$NEW_BOUNCER_VERSION" ]] || set_bouncer_version "$NEW_BOUNCER_VERSION" "$UPGRADE_COMPOSE"

        COMPOSE_FILE="$UPGRADE_COMPOSE_NAME" docker compose config --quiet
        if cmp -s "$COMPOSE_FILE_NAME" "$UPGRADE_COMPOSE"; then
            info "$COMPOSE_FILE_NAME already has the requested versions."
            rm -f "$UPGRADE_COMPOSE"
            UPGRADE_COMPOSE=""
        else
            PULL_COMPOSE_FILE="$UPGRADE_COMPOSE_NAME"
            diff -u "$COMPOSE_FILE_NAME" "$UPGRADE_COMPOSE" || true
        fi
    fi
}

# Written only after the backup, so the rollback point still holds the old file
apply_compose_changes() {
    if [[ -n "$UPGRADE_COMPOSE" ]]; then
        mv "$UPGRADE_COMPOSE" "$NETBIRD_DIR/$COMPOSE_FILE_NAME"
        success "$COMPOSE_FILE_NAME updated."
    fi
}

# ── 2. Pull + compare ─────────────────────────────────────────────────────────
pull_images() {
    step "Pulling new images"
    COMPOSE_FILE="$PULL_COMPOSE_FILE" docker compose pull "${SERVICES[@]}"

    declare -gA NEW_ID
    CHANGED=false
    [[ -z "$UPGRADE_COMPOSE" ]] || CHANGED=true
    printf "\n  %-16s %-22s %-22s\n" "SERVICE" "CURRENT" "NEW"
    for svc in "${SERVICES[@]}"; do
        NEW_ID[$svc]=$(docker image inspect -f '{{.Id}}' "${TARGET_REF[$svc]}")
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
    if [[ ${#EDGE_SERVICES[@]} -gt 0 ]]; then
        info "Traefik / CrowdSec follow the tags in docker-compose.yml, not the NetBird release:"
        info "  https://docs.netbird.io/selfhosted/maintenance/upgrade (validated versions)"
    fi
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
    docker compose config --quiet
    docker compose up -d --no-deps --force-recreate "${NETBIRD_SERVICES[@]}"

    # One at a time, so a broken component is visible before the next one is touched
    for svc in "${EDGE_SERVICES[@]}"; do
        info "Recreating $svc"
        docker compose up -d --no-deps --force-recreate "$svc"
    done
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
    check_traefik_network
    prepare_compose_changes
    pull_images

    confirm "Upgrade now? NetBird will be stopped briefly for the backup and restarted twice." \
        || { info "Upgrade cancelled."; exit 0; }

    create_rollback_point
    apply_compose_changes
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
