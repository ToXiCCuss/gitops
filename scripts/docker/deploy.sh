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
#
# Projects in VAULT_PROJECTS get their secrets from Vault (KV engine docker, path
# docker/<project>) as well: the script logs in with the AppRole of
# /etc/gitops/role_id and /etc/gitops/secret_id, writes the keys to
# /run/gitops/<project>/vault.env (tmpfs, mode 600) for the compose file and removes
# the file again after the container was started. Required variables are checked over
# override.env and vault.env together. If Vault cannot be reached, that project is not
# deployed (no fallback). Needs curl and jq.
#
# A project can have a pre-deploy.sh: it is run with bash after the variables were
# checked and before the container is started. If it fails, that project is not deployed.
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
ALL_PROJECTS=(seaweedfs restic-backup databasus keycloak keycloak-config offsite-sync vault-backup pelicanPanel pelicanWings cadvisor)

# Projects whose secrets come from Vault (docker/<project>), see the README
VAULT_PROJECTS=(keycloak keycloak-config)
VAULT_ADDR="${VAULT_ADDR:-https://vault.k8sdev.rjst.de}"
VAULT_KV_MOUNT="docker"
VAULT_ROLE_ID_FILE="/etc/gitops/role_id"
VAULT_SECRET_ID_FILE="/etc/gitops/secret_id"
VAULT_ENV_DIR="/run/gitops"
VAULT_TIMEOUT_SECONDS=15

PULL=""
ADOPT=""
LIST=""
PROJECTS=()
VAULT_TOKEN=""
VAULT_ENV_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)  PULL=1; shift ;;
        --adopt) ADOPT=1; shift ;;
        --list)  LIST=1; shift ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

is_vault_project() {
    [[ " ${VAULT_PROJECTS[*]} " == *" $1 "* ]]
}

# Credentials for Vault requests: -H @- reads the header from stdin, the token stays out of the process list
vault_header() {
    printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN"
}

# vault_login: AppRole login, sets VAULT_TOKEN. The files are read by jq and curl, the secret_id is no argument
vault_login() {
    local file response
    for file in "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE"; do
        [[ -r "$file" ]] || { error "Vault login: $file is missing (README: Secrets from Vault)"; return 1; }
    done
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { error "curl and jq are required for the projects with secrets from Vault"; return 1; }
    response=$(jq -n --rawfile role_id "$VAULT_ROLE_ID_FILE" --rawfile secret_id "$VAULT_SECRET_ID_FILE" \
        '{role_id: ($role_id | rtrimstr("\n")), secret_id: ($secret_id | rtrimstr("\n"))}' \
        | curl -fsS -m "$VAULT_TIMEOUT_SECONDS" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/auth/approle/login") \
        || { error "Vault login at $VAULT_ADDR failed: Vault not reachable, wrong secret_id or an address outside the CIDR of the role"; return 1; }
    VAULT_TOKEN=$(jq -r '.auth.client_token // empty' <<<"$response")
    [[ -n "$VAULT_TOKEN" ]] || { error "Vault login: the response holds no token"; return 1; }
}

# Reads the keys of a secret as NAME='value' lines (single quotes: Compose does not interpolate $ in them).
# A name or value Compose could not read back unchanged (a single quote or a control character such as a
# line break in the value) is an error
VAULT_ENV_PROGRAM='
.data.data
| to_entries[]
| if (.key | test("^[A-Za-z_][A-Za-z0-9_]*$")) and (.value | type == "string") and ((.value | contains($quote) or test("[\\x00-\\x1f]")) | not)
  then "\(.key)=\($quote)\(.value)\($quote)"
  else error("unusable name or value for the key \(.key)") end'

# write_vault_env <project>: docker/<project> from Vault to /run/gitops/<project>/vault.env
write_vault_env() {
    local directory="$VAULT_ENV_DIR/$1" file="$VAULT_ENV_DIR/$1/vault.env" response
    [[ -n "$VAULT_TOKEN" ]] || vault_login || return 1
    response=$(vault_header | curl -fsS -m "$VAULT_TIMEOUT_SECONDS" -H @- "$VAULT_ADDR/v1/$VAULT_KV_MOUNT/data/$1") \
        || { error "$1: cannot read $VAULT_KV_MOUNT/$1 from Vault (does the secret exist, does the policy allow it?)"; return 1; }
    install -d -m 700 "$VAULT_ENV_DIR" "$directory"
    VAULT_ENV_FILES+=("$file")
    (umask 077; jq -r --arg quote "'" "$VAULT_ENV_PROGRAM" <<<"$response" > "$file") \
        || { error "$1: the secret $VAULT_KV_MOUNT/$1 cannot be written as an env file (see the message above)"; rm -f "$file"; return 1; }
    [[ -s "$file" ]] || { error "$1: the secret $VAULT_KV_MOUNT/$1 holds no keys"; rm -f "$file"; return 1; }
    info "$1: $(wc -l < "$file") keys from Vault ($VAULT_KV_MOUNT/$1)"
}

remove_vault_env() {
    rm -f "$VAULT_ENV_DIR/$1/vault.env"
}

# The token is revoked and the env files are removed whatever happens
cleanup() {
    local file
    for file in "${VAULT_ENV_FILES[@]+"${VAULT_ENV_FILES[@]}"}"; do
        rm -f "$file"
    done
    if [[ -n "$VAULT_TOKEN" ]]; then
        vault_header | curl -fsS -m "$VAULT_TIMEOUT_SECONDS" -X POST -H @- "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# check_env <project>: every required variable of override.env.example must have a value in override.env
# or, for the projects with secrets from Vault, in vault.env (the last file wins, as in the compose file)
check_env() {
    local example="$DOCKER_DIR/$1/override.env.example" files=() missing=() name value file source_name="override.env"
    [[ -f "$example" ]] || return 0
    for file in "$DOCKER_DIR/$1/override.env" "$VAULT_ENV_DIR/$1/vault.env"; do
        [[ ! -f "$file" ]] || files+=("$file")
    done
    if is_vault_project "$1"; then
        source_name="override.env and Vault"
    fi
    if [[ ${#files[@]} -eq 0 ]]; then
        error "$1: no $source_name. Copy override.env.example and fill it in"
        return 1
    fi
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        value=$(grep -h "^$name=" "${files[@]}" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true)
        [[ -n "$value" ]] || missing+=("$name")
    done < "$example"
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "$1: missing or empty in $source_name: ${missing[*]}"
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
    if is_vault_project "$project"; then
        write_vault_env "$project" || { FAILED+=("$project"); continue; }
    fi
    check_env "$project" || { FAILED+=("$project"); continue; }
    if [[ -f "$dir/pre-deploy.sh" ]]; then
        bash "$dir/pre-deploy.sh" || { error "$project: pre-deploy.sh failed"; FAILED+=("$project"); continue; }
    fi

    proj="${project,,}"
    [[ -z "$ADOPT" ]] || adopt "$project" "$proj"
    if (cd "$dir" && docker compose -p "$proj" up -d); then
        success "$project is up"
    else
        error "$project failed (a container of the same name from another project? try --adopt)"
        FAILED+=("$project")
    fi
    remove_vault_env "$project"
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Failed: ${FAILED[*]}"
    exit 1
fi
success "Done: ${PROJECTS[*]}"
