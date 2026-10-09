#!/bin/bash
# =============================================================================
# undeploy.sh
# Stops and removes the containers and networks of Docker Compose projects of docker/ on the
# Docker host (counterpart of deploy.sh). The data stays: the folders below /root/docker and
# the named volumes are never touched.
#
#   sudo scripts/docker/undeploy.sh [--yes] project [project ...]
#
#   --yes   do not ask for confirmation
#
# A project name is required, there is no "all". The containers are found by the Compose label
# of the project (the lower case name that deploy.sh uses), so it also works for a project that
# was already removed from docker/. Containers that were not created by deploy.sh carry another
# project name or none: remove them with docker rm -f (see: docker compose ls).
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

ASSUME_YES=""
PROJECTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) error "Unknown argument: $1"; exit 1 ;;
        *)  PROJECTS+=("$1"); shift ;;
    esac
done

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
    error "Name at least one project (the folders of docker/, see scripts/docker/deploy.sh --list)"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/undeploy.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }

# compose_ids <resource> <compose project>: ids or names of the resources that belong to the project
compose_ids() {
    case "$1" in
        container) docker ps -a --filter "label=com.docker.compose.project=$2" --format '{{.Names}}' ;;
        network)   docker network ls --filter "label=com.docker.compose.project=$2" --format '{{.Name}}' ;;
        volume)    docker volume ls --filter "label=com.docker.compose.project=$2" --format '{{.Name}}' ;;
    esac
}

# confirmed: true unless the user answers anything but y/Y (or --yes was given)
confirmed() {
    local answer
    [[ -n "$ASSUME_YES" ]] && return 0
    read -r -p "Stop and remove these containers? [y/N] " answer
    [[ "$answer" =~ ^[yY]$ ]]
}

remove_networks() {
    local network
    for network in $(compose_ids network "$1"); do
        docker network rm "$network" >/dev/null 2>&1 || warn "Network $network is still in use by other containers, left in place"
    done
}

FAILED=()
for project in "${PROJECTS[@]}"; do
    step "$project"
    proj="${project,,}"
    containers=$(compose_ids container "$proj")
    if [[ -z "$containers" ]]; then
        warn "$project: no container with the Compose project '$proj' found"
        FAILED+=("$project")
        continue
    fi
    echo "$containers" | sed 's/^/  /'
    if ! confirmed; then
        warn "$project: skipped"
        continue
    fi
    echo "$containers" | xargs docker rm -f >/dev/null
    remove_networks "$proj"
    success "$project is removed"
    volumes=$(compose_ids volume "$proj")
    [[ -z "$volumes" ]] || info "Named volumes stay: $(echo "$volumes" | tr '\n' ' ')"
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Nothing found for: ${FAILED[*]}"
    exit 1
fi
success "Done: ${PROJECTS[*]}"
