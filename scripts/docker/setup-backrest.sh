#!/bin/bash
# =============================================================================
# setup-backrest.sh
# Fills docker/backrest/override.env with the secrets that pre-deploy.sh puts into the Backrest
# configuration, as far as they can be found on this host. A value that is already set is never
# changed. Run it after setup-backup-host.sh (it writes the S3 keys) and before deploying Backrest.
#
#   sudo scripts/docker/setup-backrest.sh
#
# Where the values come from:
#   RESTIC_PASSWORD_VAULT    docker/vault-backup/override.env (RESTIC_PASSWORD, the same repository)
#   RESTIC_PASSWORD_NETBIRD  /root/restic (written by netbird_backup_setup.sh)
#   RESTIC_PASSWORD_DOCKER   asked for. An empty answer generates a new password (fresh setup only),
#                            it is shown once, put it into the password manager
#   DISCORD_WEBHOOK_URL      docker/offsite-sync/override.env, if it is set there
#
# Afterwards: bash docker/backrest/pre-deploy.sh /tmp/config.test.json, then
# sudo scripts/docker/deploy.sh backrest
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
ENV_FILE="$REPO_DIR/docker/backrest/override.env"
VAULT_BACKUP_ENV="$REPO_DIR/docker/vault-backup/override.env"
OFFSITE_SYNC_ENV="$REPO_DIR/docker/offsite-sync/override.env"
NETBIRD_PASSWORD_FILE="${NETBIRD_PASSWORD_FILE:-/root/restic}"
GENERATED_PASSWORD_BYTES=24

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/setup-backrest.sh)"
    exit 1
fi

# value_of <file> <NAME>: the last assignment of NAME in the file, empty if there is none
value_of() {
    [[ -f "$1" ]] || return 0
    grep "^$2=" "$1" | tail -n 1 | cut -d= -f2- || true
}

has_value() {
    [[ -n "$(value_of "$ENV_FILE" "$1")" ]]
}

# set_value <NAME> <value>: replaces the line of NAME in override.env or adds it, safe for any characters
set_value() {
    local temporary
    temporary=$(mktemp "$ENV_FILE.XXXXXX")
    { grep -v "^$1=" "$ENV_FILE" || true; } > "$temporary"
    printf '%s=%s\n' "$1" "$2" >> "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$ENV_FILE"
}

# first_line_of <file>: the first line of a file, empty if the file does not exist
first_line_of() {
    [[ -f "$1" ]] || return 0
    head -n 1 "$1"
}

# fill_from <NAME> <value> <source>: takes the value unless NAME is set already
fill_from() {
    if has_value "$1"; then
        info "$1 is set already, kept"
    elif [[ -n "$2" ]]; then
        set_value "$1" "$2"
        success "$1 taken from $3"
    else
        return 1
    fi
}

# ask_for <question>: reads one line without echo. The prompt and the line break go to stderr, so that
# only the answer is captured by $( )
ask_for() {
    local answer
    read -rsp "  $1: " answer
    echo >&2
    printf '%s' "$answer"
}

fill_required_password() {
    local answer
    fill_from "$1" "$2" "$3" && return 0
    warn "$1: not found in $3"
    answer=$(ask_for "Enter the password of the repository $4")
    [[ -n "$answer" ]] || { error "$1 is required"; exit 1; }
    set_value "$1" "$answer"
    success "$1 set"
}

fill_docker_password() {
    local answer
    if has_value RESTIC_PASSWORD_DOCKER; then
        info "RESTIC_PASSWORD_DOCKER is set already, kept"
        return 0
    fi
    answer=$(ask_for "Password of the repository docker (empty = generate a new one, fresh setup only)")
    if [[ -z "$answer" ]]; then
        answer=$(openssl rand -base64 "$GENERATED_PASSWORD_BYTES" | tr -d '/+=\n')
        warn "Generated password for the repository docker, it is shown only now: $answer"
        warn "Put it into the password manager. Without it the backups cannot be read."
    fi
    set_value RESTIC_PASSWORD_DOCKER "$answer"
    success "RESTIC_PASSWORD_DOCKER set"
}

step "Preparing $ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
    install -m 600 /dev/null "$ENV_FILE"
    info "Created the file"
fi
chmod 600 "$ENV_FILE"

step "S3 keys of the identity backrest"
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if ! has_value "$name"; then
        error "$name is missing. Run scripts/docker/setup-backup-host.sh first, it writes the S3 keys."
        exit 1
    fi
done
success "Both S3 keys are there"

step "Restic passwords"
fill_docker_password
fill_required_password RESTIC_PASSWORD_VAULT "$(value_of "$VAULT_BACKUP_ENV" RESTIC_PASSWORD)" \
    "docker/vault-backup/override.env" "vault"
fill_required_password RESTIC_PASSWORD_NETBIRD "$(first_line_of "$NETBIRD_PASSWORD_FILE")" \
    "$NETBIRD_PASSWORD_FILE" "netbird"

step "Discord webhook"
fill_from DISCORD_WEBHOOK_URL "$(value_of "$OFFSITE_SYNC_ENV" DISCORD_WEBHOOK_URL)" "docker/offsite-sync/override.env" \
    || info "No webhook found, Backrest will not report failures (set DISCORD_WEBHOOK_URL in override.env by hand)"

echo
success "Done. Check the result with: bash docker/backrest/pre-deploy.sh /tmp/config.test.json"
info "Then deploy: sudo scripts/docker/deploy.sh backrest"
