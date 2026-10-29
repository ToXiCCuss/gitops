#!/bin/bash
# =============================================================================
# deploy.sh
# Deploys the Docker Compose projects of docker/ on the Docker host (replaces the
# management UI). Idempotent: a project is only recreated when its compose file or
# its environment changed.
#
#   sudo scripts/docker/deploy.sh [--pull] [--adopt] [--list] [--metrics-file FILE] [project ...]
#
#   --pull   git pull --ff-only in the repository first
#   --adopt  remove an existing container of the same name that belongs to another
#            Compose project (created by the old management UI) so that it is created
#            again by this script. Data lives in folders on the host and stays
#   --list   list the projects and exit
#   --metrics-file FILE
#            write the result of the run for the node_exporter textfile collector
#            (gitops_deploy_* metrics, see the README). The gitops-deploy timer sets it
#
# Without a project name all projects are deployed in a fixed order.
#
# The secrets of a project are in Vault (KV engine docker, path docker/<project>), never in a file
# of the repository or of the host. A project that has a docker/<project>/vault.env.example gets them:
# the script logs in with the AppRole of /etc/gitops/role_id and /etc/gitops/secret_id, writes the
# keys to /run/gitops/<project>/vault.env (tmpfs, mode 600) for the compose file and removes the file
# again after the container was started. The names a project needs are in vault.env.example:
# NAME= is required, #NAME= is optional. A missing or empty required variable stops the deploy of that
# project before anything is changed. If Vault cannot be reached, that project is not deployed (no
# fallback). A project in S3_IDENTITIES also gets the keys of its S3 identity (docker/s3/<identity>)
# as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Needs curl and jq.
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
ALL_PROJECTS=(rustfs restic-backup keycloak keycloak-config offsite-sync vault-backup pelicanPanel pelicanWings cadvisor)

# Projects that need the keys of an S3 identity (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY), as project:identity.
# The keys are docker/s3/<identity> in Vault (scripts/vault/create-s3-identities.ps1)
S3_IDENTITIES=(restic-backup:restic-backup offsite-sync:offsite-sync vault-backup:vault)
VAULT_ADDR="${VAULT_ADDR:-https://vault.k8sdev.rjst.de}"
VAULT_KV_MOUNT="docker"
VAULT_ROLE_ID_FILE="/etc/gitops/role_id"
VAULT_SECRET_ID_FILE="/etc/gitops/secret_id"
VAULT_ENV_DIR="/run/gitops"
VAULT_TIMEOUT_SECONDS=15

PULL=""
ADOPT=""
LIST=""
METRICS_FILE=""
PROJECTS=()
VAULT_TOKEN=""
VAULT_ENV_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull)  PULL=1; shift ;;
        --adopt) ADOPT=1; shift ;;
        --list)  LIST=1; shift ;;
        --metrics-file) [[ -n "${2:-}" ]] || { error "--metrics-file needs a file name"; exit 1; }
                        METRICS_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

PULL_OK=1
FAILED=()
SUCCEEDED=()

# previous_success_time: the time of the last successful run from the previous metrics file, 0 if there is none
previous_success_time() {
    local previous
    previous=$(sed -n 's/^gitops_deploy_last_success_timestamp_seconds //p' "$METRICS_FILE" 2>/dev/null | head -n 1) || true
    echo "${previous:-0}"
}

# print_metrics <now> <time of the last success> <revision>: the metrics of this run in the format of the textfile collector
print_metrics() {
    local project
    printf 'gitops_deploy_pull_success %s
' "$PULL_OK"
    printf 'gitops_deploy_last_run_timestamp_seconds %s
' "$1"
    printf 'gitops_deploy_last_success_timestamp_seconds %s
' "$2"
    printf 'gitops_deploy_revision_info{revision="%s"} 1
' "$3"
    for project in ${SUCCEEDED[@]+"${SUCCEEDED[@]}"}; do
        printf 'gitops_deploy_project_success{project="%s"} 1
' "$project"
    done
    for project in ${FAILED[@]+"${FAILED[@]}"}; do
        printf 'gitops_deploy_project_success{project="%s"} 0
' "$project"
    done
}

# write_metrics: the result of this run for the textfile collector of the node_exporter. It is written to a
# temporary file and moved, so the node_exporter never reads a half written file. The time of the last
# success stays as it was when a run fails, Prometheus alerts when it gets too old
write_metrics() {
    local now last_success revision
    if [[ -n "$METRICS_FILE" ]]; then
        now=$(date +%s)
        last_success=$(previous_success_time)
        if [[ "$PULL_OK" == 1 && ${#FAILED[@]} -eq 0 ]]; then
            last_success="$now"
        fi
        revision=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null) || revision="unknown"
        if ! print_metrics "$now" "$last_success" "$revision" > "$METRICS_FILE.tmp" || ! mv "$METRICS_FILE.tmp" "$METRICS_FILE"; then
            warn "Writing the metrics to $METRICS_FILE failed"
        fi
    fi
}

if [[ -n "$PULL" ]]; then
    step "git pull"
    if ! git -C "$REPO_DIR" pull --ff-only; then
        error "git pull failed (local changes or a diverged branch?), nothing is deployed"
        PULL_OK=0
        write_metrics
        exit 1
    fi
fi

# A project gets its secrets from Vault if it names the keys it needs in vault.env.example
is_vault_project() {
    [[ -f "$DOCKER_DIR/$1/vault.env.example" ]]
}

# s3_identity_of <project>: the S3 identity of the project, empty if it has none
s3_identity_of() {
    local entry
    for entry in "${S3_IDENTITIES[@]}"; do
        [[ "${entry%%:*}" != "$1" ]] || echo "${entry#*:}"
    done
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
        | curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/auth/approle/login") \
        || { error "Vault login: $VAULT_ADDR is not reachable"; return 1; }
    VAULT_TOKEN=$(jq -r '.auth.client_token // empty' <<<"$response" 2>/dev/null)
    [[ -n "$VAULT_TOKEN" ]] || { error "Vault login refused: $(vault_errors "$response")"; return 1; }
}

# vault_errors <response>: the error messages of a Vault answer, empty if it has none
vault_errors() {
    jq -r '(.errors // []) | join("; ")' <<<"$1" 2>/dev/null || true
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

# vault_get <path>: the answer of Vault for the KV secret docker/<path>, an error if it holds no data
vault_get() {
    local response
    response=$(vault_header | curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H @- "$VAULT_ADDR/v1/$VAULT_KV_MOUNT/data/$1") \
        || { error "$VAULT_ADDR is not reachable"; return 1; }
    jq -e '.data.data' >/dev/null 2>&1 <<<"$response" \
        || { error "cannot read $VAULT_KV_MOUNT/$1 from Vault (does the secret exist, does the policy allow it?) $(vault_errors "$response")"; return 1; }
    printf '%s' "$response"
}

# append_secret_env <project> <file>: the keys of docker/<project> as NAME='value' lines
append_secret_env() {
    local response
    response=$(vault_get "$1") || return 1
    (umask 077; jq -r --arg quote "'" "$VAULT_ENV_PROGRAM" <<<"$response" >> "$2") \
        || { error "$1: the secret $VAULT_KV_MOUNT/$1 cannot be written as an env file (see the message above)"; return 1; }
}

# append_s3_keys <project> <identity> <file>: the keys of the S3 identity docker/s3/<identity> as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
append_s3_keys() {
    local response
    response=$(vault_get "s3/$2") || return 1
    (umask 077; jq -er --arg quote "'" '
        .data.data | select(.access_key and .secret_key)
        | "AWS_ACCESS_KEY_ID=\($quote)\(.access_key)\($quote)", "AWS_SECRET_ACCESS_KEY=\($quote)\(.secret_key)\($quote)"' \
        <<<"$response" >> "$3") \
        || { error "$1: $VAULT_KV_MOUNT/s3/$2 holds no access_key and secret_key (scripts/vault/create-s3-identities.ps1)"; return 1; }
}

# write_vault_env <project>: the secrets of the project from Vault to /run/gitops/<project>/vault.env
write_vault_env() {
    local directory="$VAULT_ENV_DIR/$1" file="$VAULT_ENV_DIR/$1/vault.env" identity
    identity=$(s3_identity_of "$1")
    [[ -n "$VAULT_TOKEN" ]] || vault_login || return 1
    install -d -m 700 "$VAULT_ENV_DIR" "$directory"
    VAULT_ENV_FILES+=("$file")
    (umask 077; : > "$file")
    append_secret_env "$1" "$file" || { rm -f "$file"; return 1; }
    if [[ -n "$identity" ]]; then
        append_s3_keys "$1" "$identity" "$file" || { rm -f "$file"; return 1; }
    fi
    [[ -s "$file" ]] || { error "$1: Vault holds no keys for this project"; rm -f "$file"; return 1; }
    info "$1: $(wc -l < "$file") keys from Vault"
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

# check_env <project>: every required variable of vault.env.example must have a value in the keys from Vault
check_env() {
    local example="$DOCKER_DIR/$1/vault.env.example" file="$VAULT_ENV_DIR/$1/vault.env" missing=() name value
    [[ -f "$example" ]] || return 0
    [[ -f "$file" ]] || { error "$1: the keys from Vault are missing"; return 1; }
    while IFS= read -r line; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        name="${BASH_REMATCH[1]}"
        value=$(grep "^$name=" "$file" | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true)
        [[ -n "$value" ]] || missing+=("$name")
    done < "$example"
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "$1: missing or empty in Vault ($VAULT_KV_MOUNT/$1 or its S3 identity): ${missing[*]}"
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

for project in "${PROJECTS[@]}"; do
    step "$project"
    dir="$DOCKER_DIR/$project"
    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        error "$project: $dir/docker-compose.yml not found (projects: ${ALL_PROJECTS[*]})"
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
        SUCCEEDED+=("$project")
    else
        error "$project failed (a container of the same name from another project? try --adopt)"
        FAILED+=("$project")
    fi
    remove_vault_env "$project"
done

echo
write_metrics
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Failed: ${FAILED[*]}"
    exit 1
fi
success "Done: ${PROJECTS[*]}"
