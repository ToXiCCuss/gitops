#!/bin/bash
# =============================================================================
# restart-host-network.sh
# Restarts the containers that run in the host network. Run it after apt upgrade, or whenever NetBird
# changed the DNS of the host.
#
#   sudo scripts/docker/restart-host-network.sh
#
# Why: a container copies the resolv.conf of the host when it starts. If NetBird changes the resolver
# of the host afterwards, a container in the host network keeps the old copy and cannot resolve the
# NetBird names any more (vault-backup: "Could not resolve host: vault.k8sdev.rjst.de") while the host
# still can. A restart copies the file again. The other containers have their own network and DNS and
# are not affected, so they are left alone.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

HOST_NETWORK_MODE="host"

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/restart-host-network.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }

# running containers whose network mode is "host"
find_host_network_containers() {
    local name
    for name in $(docker ps --format '{{.Names}}'); do
        if [[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$name")" == "$HOST_NETWORK_MODE" ]]; then
            echo "$name"
        fi
    done
}

step "Containers in the host network"
mapfile -t CONTAINERS < <(find_host_network_containers)

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    info "None is running, nothing to restart"
    exit 0
fi
info "${CONTAINERS[*]}"

FAILED=()
for name in "${CONTAINERS[@]}"; do
    step "$name"
    if docker restart "$name" >/dev/null; then
        success "$name restarted"
    else
        error "$name could not be restarted"
        FAILED+=("$name")
    fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Failed: ${FAILED[*]}"
    exit 1
fi
success "Done: ${CONTAINERS[*]}"
