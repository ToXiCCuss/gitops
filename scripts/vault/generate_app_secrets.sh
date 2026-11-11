#!/bin/bash
# =============================================================================
# generate_app_secrets.sh
# Creates the random secrets of the Spring apps in Vault (KV engines dev and prod) that do not exist yet, from the list
# scripts/vault/generated-app-secrets.txt (<app> <key> <length>, one key per line). A key that exists is never changed.
# The secret of an app is <environment>/<app>, for example prod/er-launcher-service.
#
#   vault login -method=oidc role=default      # once, with your own Keycloak login (not the root token)
#   scripts/vault/generate_app_secrets.sh [--dry-run] <dev|prod|all>
#
# Idempotent: a second run reports "unchanged". Values come from `openssl rand`, go to Vault through stdin (not through the
# command line, so `ps` does not show them) and are never printed. Values that are set from outside (Discord secret, webhooks)
# or by other scripts (database logins, S3 keys: setup-rustfs.sh, db_create.sh) are not in the list.
# The login needs the policy keycloak_developer (create, read, update in dev/ and prod/); the AppRole of docker01 cannot write
# there on purpose.
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
LIST_FILE="${GENERATED_APP_SECRETS_LIST:-$REPO_DIR/scripts/vault/generated-app-secrets.txt}"

MINIMUM_LENGTH=32
MAXIMUM_LENGTH=128
ALPHABET='A-Za-z0-9'
APP_PATTERN='^[a-z][a-z0-9-]*$'
KEY_PATTERN='^[A-Za-z][A-Za-z0-9._-]*$'

export VAULT_ADDR="${VAULT_ADDR:-https://vault.k8sdev.rjst.de}"
DRY_RUN=false
ENVIRONMENTS=()
CREATED=0
UNCHANGED=0
FAILED=0

usage() {
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        dev|prod)  ENVIRONMENTS+=("$1"); shift ;;
        all)       ENVIRONMENTS=(dev prod); shift ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $1 (dev, prod or all, optionally --dry-run)"; exit 1 ;;
    esac
done
if [[ ${#ENVIRONMENTS[@]} -eq 0 ]]; then
    error "Name the environment: dev, prod or all"
    exit 1
fi

for tool in vault openssl tr head; do
    command -v "$tool" >/dev/null 2>&1 || { error "$tool is required"; exit 1; }
done
[[ -r "$LIST_FILE" ]] || { error "List not found: $LIST_FILE"; exit 1; }

# ── Login ─────────────────────────────────────────────────────────────────────
# The token of your own login is used as it is (vault login writes ~/.vault-token). The root token is refused: it needs no
# policy to write anything, and a script that runs with it could change every secret.
check_login() {
    local lookup
    lookup=$(vault token lookup 2>&1) || {
        error "Not logged in to $VAULT_ADDR. Log in first: vault login -method=oidc role=default"
        return 1
    }
    if grep -E '^policies' <<<"$lookup" | grep -qw root; then
        error "Logged in with the root token. Use your own login: vault login -method=oidc role=default"
        return 1
    fi
}

# generate <length>: random alphanumeric text. tr and openssl may end with SIGPIPE when head has enough, so only the length counts
generate() {
    local value
    value=$(openssl rand -base64 300 | tr -dc "$ALPHABET" | head -c "$1" || true)
    [[ ${#value} -eq $1 ]] || { error "could not generate $1 characters"; return 1; }
    printf '%s' "$value"
}

# store <environment> <app> <key> <value>: patch keeps the other keys of the secret, put with -cas=0 creates a secret that does not
# exist yet and never overwrites one. The value goes through stdin.
store() {
    printf '%s' "$4" | vault kv patch -method=rw -mount="$1" "$2" "$3=-" >/dev/null 2>&1 \
        || printf '%s' "$4" | vault kv put -cas=0 -mount="$1" "$2" "$3=-" >/dev/null
}

# validate_line <app> <key> <length>: the list is read by a script that writes to Vault, so every field is checked
validate_line() {
    [[ "$1" =~ $APP_PATTERN ]] || { error "Invalid app name in the list: $1"; return 1; }
    [[ "$2" =~ $KEY_PATTERN ]] || { error "Invalid key in the list: $2"; return 1; }
    [[ "$3" =~ ^[0-9]+$ && "$3" -ge $MINIMUM_LENGTH && "$3" -le $MAXIMUM_LENGTH ]] \
        || { error "Invalid length for $1 $2: $3 (from $MINIMUM_LENGTH to $MAXIMUM_LENGTH)"; return 1; }
}

ensure_key() {
    local environment="$1" app="$2" key="$3" length="$4"
    if vault kv get -mount="$environment" -field="$key" "$app" >/dev/null 2>&1; then
        UNCHANGED=$((UNCHANGED + 1))
        info "$environment/$app $key: unchanged"
    elif [[ "$DRY_RUN" == true ]]; then
        CREATED=$((CREATED + 1))
        warn "$environment/$app $key: would be created ($length characters)"
    elif store "$environment" "$app" "$key" "$(generate "$length")"; then
        CREATED=$((CREATED + 1))
        success "$environment/$app $key: created ($length characters)"
    else
        FAILED=$((FAILED + 1))
        error "$environment/$app $key: could not be written (does your login have create and update in $environment/?)"
    fi
}

step "Login at $VAULT_ADDR"
check_login
success "Logged in with your own token"

for environment in "${ENVIRONMENTS[@]}"; do
    step "Environment $environment"
    while read -r app key length; do
        validate_line "$app" "$key" "$length" || exit 1
        ensure_key "$environment" "$app" "$key" "$length"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$LIST_FILE")
done

echo
if [[ "$DRY_RUN" == true ]]; then
    info "Dry run: $CREATED key(s) would be created, $UNCHANGED unchanged. Nothing was written."
else
    info "$CREATED key(s) created, $UNCHANGED unchanged, $FAILED failed."
fi
[[ $FAILED -eq 0 ]]
