#!/bin/bash
# =============================================================================
# deploy.sh
# Deploys the Docker Compose projects of docker/ on the Docker host (replaces the
# management UI). Idempotent: a project is only recreated when its compose file or
# its environment changed.
#
#   sudo scripts/docker/deploy.sh [--pull] [--adopt] [--list] [project ...]
#
#   --pull   git pull --ff-only in the repository first
#   --adopt  remove an existing container of the same name that belongs to another
#            Compose project (created by the old management UI) so that it is created
#            again by this script. Data lives in folders on the host and stays
#   --list   list the projects and exit
#
# Without a project name all projects are deployed in a fixed order.
#
# The secrets of a project are in docker/<project>/override.env (not in Git). The
# variables a project needs are named in docker/<project>/override.env.example:
# NAME= is required, #NAME= is optional. A missing or empty required variable
# stops the deploy of that project before anything is changed.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER_DIR="$REPO_DIR/docker"

# Order: the S3 first, the services that write to it afterwards
ALL_PROJECTS=(seaweedfs backrest databasus offsite-sync vault-backup uptimeKuma pelicanPanel pelicanWings cadvisor)

PULL=""
ADOPT=""
LIST=""
PROJECTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)  PULL=1; shift ;;
        --adopt) ADOPT=1; shift ;;
        --list)  LIST=1; shift ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) error "Unknown argument: $1"; exit 1 ;;
        *)  PROJECTS+=("$1"); shift ;;
    esac
done

if [[ -n "$LIST" ]]; then
    printf '%s\n' "${ALL_PROJECTS[@]}"
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/deploy.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 || { error "docker with the compose plugin is required"; exit 1; }

[[ ${#PROJECTS[@]} -gt 0 ]] || PROJECTS=("${ALL_PROJECTS[@]}")

if [[ -n "$PULL" ]]; then
    step "git pull"
    git -C "$REPO_DIR" pull --ff-only
fi

# check_env <project>: every required variable of override.env.example must have a value in override.env
check_env() {
    local dir="$DOCKER_DIR/$1" example="$DOCKER_DIR/$1/override.env.example" file="$DOCKER_DIR/$1/override.env" missing=() name value
    [[ -f "$example" ]] || return 0
    if [[ ! -f "$file" ]]; then
        error "$1: $file is missing. Copy override.env.example and fill it in"
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        value=$(grep -m1 "^$name=" "$file" | cut -d= -f2- | tr -d "\"'" || true)
        [[ -n "$value" ]] || missing+=("$name")
    done < "$example"
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "$1: missing or empty in override.env: ${missing[*]}"
        return 1
    fi
}

# adopt <project> <compose project name>: remove containers of the same name that belong to another project
adopt() {
    local name label
    for name in $(awk '/^[[:space:]]*container_name:/ {print $2}' "$DOCKER_DIR/$1/docker-compose.yml"); do
        docker inspect "$name" >/dev/null 2>&1 || continue
        label=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name")
        if [[ "$label" != "$2" ]]; then
            warn "$1: container '$name' belongs to the Compose project '${label:-none}', removing it (its data stays)"
            docker rm -f "$name" >/dev/null
        fi
    done
}

FAILED=()
for project in "${PROJECTS[@]}"; do
    step "$project"
    dir="$DOCKER_DIR/$project"
    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        error "$project: $dir/docker-compose.yml not found (projects: ${ALL_PROJECTS[*]})"
        FAILED+=("$project")
        continue
    fi
    if [[ "$project" == "seaweedfs" && ! -f /root/docker/seaweedfs-s3.json ]]; then
        error "seaweedfs: /root/docker/seaweedfs-s3.json is missing. Run scripts/docker/setup-backup-host.sh first"
        FAILED+=("$project")
        continue
    fi
    check_env "$project" || { FAILED+=("$project"); continue; }

    proj="${project,,}"
    [[ -z "$ADOPT" ]] || adopt "$project" "$proj"
    if (cd "$dir" && docker compose -p "$proj" up -d); then
        success "$project is up"
    else
        error "$project failed (a container of the same name from another project? try --adopt)"
        FAILED+=("$project")
    fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Failed: ${FAILED[*]}"
    exit 1
fi
success "Done: ${PROJECTS[*]}"
