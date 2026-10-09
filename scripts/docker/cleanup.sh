#!/bin/bash
# =============================================================================
# cleanup.sh
# Shows what Docker keeps that nothing uses any more and removes the part that is safe to remove
# (images without a name and the build cache). Everything else is only listed, check it by hand.
#
#   sudo scripts/docker/cleanup.sh [--apply]
#
#   --apply   remove the nameless images and the build cache (default: dry run, nothing is removed)
#
# Never removed, only listed: named images without a container, volumes, stopped containers and
# networks. Volumes hold data, the images netbird-rollback/* are the rollback points of
# netbird_upgrade.sh, and Pelican creates its networks and game server containers itself.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

APPLY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/cleanup.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }

# show <command ...>: prints the output of the command, or "none" when it is empty
show() {
    local output
    output=$("$@")
    if [[ -n "$output" ]]; then echo "$output"; else echo "  none"; fi
}

nameless_images() {
    docker images --filter dangling=true --format '  {{.ID}} ({{.Size}})'
}

# Named images that no container (running or stopped) uses, without the rollback points of NetBird
unused_named_images() {
    local used
    used=$(docker ps -aq | xargs -r docker inspect --format '{{.Image}}' | sort -u)
    docker images --no-trunc --format '{{.ID}}\t{{.Repository}}:{{.Tag}}\t{{.Size}}' \
        | awk -F'\t' -v used="$used" '
            BEGIN { count = split(used, ids, "\n"); for (i = 1; i <= count; i++) inUse[ids[i]] = 1 }
            !($1 in inUse) && $2 != "<none>:<none>" && $2 !~ /^netbird-rollback\// { print "  " $2 " (" $3 ")" }'
}

unused_volumes() {
    docker volume ls --filter dangling=true --format '  {{.Name}}'
}

stopped_containers() {
    docker ps -a --filter status=exited --filter status=created --filter status=dead --format '  {{.Names}} ({{.Status}})'
}

# Networks without a container, except the three that Docker always has
unused_networks() {
    local name
    for name in $(docker network ls --format '{{.Name}}'); do
        case "$name" in bridge|host|none) continue ;; esac
        [[ "$(docker network inspect "$name" --format '{{len .Containers}}')" == "0" ]] && echo "  $name"
    done
    return 0
}

step "Disk usage"
docker system df

step "Images without a name (removed with --apply)"
show nameless_images

step "Build cache (removed with --apply)"
info "The size is the line Build Cache of the table above"

if [[ -n "$APPLY" ]]; then
    docker image prune -f >/dev/null
    docker builder prune -f >/dev/null
    success "Nameless images and build cache removed"
    step "Disk usage after"
    docker system df
fi

step "Only listed, check by hand: named images without a container"
show unused_named_images
step "Only listed, check by hand: volumes without a container"
show unused_volumes
step "Only listed, check by hand: stopped containers"
show stopped_containers
step "Only listed, check by hand: networks without a container"
show unused_networks

echo
if [[ -z "$APPLY" ]]; then
    info "Dry run, nothing was removed. Run with --apply to remove the nameless images and the build cache."
fi
