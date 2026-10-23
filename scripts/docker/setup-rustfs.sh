#!/bin/bash
# =============================================================================
# setup-rustfs.sh
# Creates the buckets, users and policies in RustFS from docker/rustfs/identities.json. The S3 keys
# of the identities are read from Vault (docker/s3/<name>, created by scripts/vault/create-s3-identities.ps1),
# the root key of RustFS comes from docker/rustfs/override.env. Idempotent: run it again after a change of
# identities.json or after a new RustFS.
#
#   sudo scripts/docker/setup-rustfs.sh [--endpoint http://127.0.0.1:9000]
#
# Buckets are created with rclone, users and policies with the MinIO client mc (RustFS serves the
# mc admin API, check the output of the first run). The policy of an identity is built from its entry:
#   readwrite  read, write and delete objects in the buckets
#   read       read and list the buckets and list all buckets (for the offsite sync)
# A user has the policy of the same name. The Docker host logs in to Vault with the AppRole of
# /etc/gitops/role_id and /etc/gitops/secret_id (see the README, Secrets from Vault).
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
IDENTITIES_FILE="$REPO_DIR/docker/rustfs/identities.json"
ROOT_ENV_FILE="$REPO_DIR/docker/rustfs/override.env"

# Not pinned yet: pin the tag (and the digest) after the first successful run, like the other images
MC_IMAGE="minio/mc:latest"
RCLONE_IMAGE="rclone/rclone:1.75.1"
S3_ENDPOINT="http://127.0.0.1:9000"
WAIT_ATTEMPTS=30
WAIT_SECONDS=2

VAULT_ADDR="${VAULT_ADDR:-https://vault.k8sdev.rjst.de}"
VAULT_KV_MOUNT="docker"
VAULT_ROLE_ID_FILE="/etc/gitops/role_id"
VAULT_SECRET_ID_FILE="/etc/gitops/secret_id"
VAULT_TIMEOUT_SECONDS=15
VAULT_TOKEN=""
POLICY_DIR=""
ROOT_ACCESS_KEY=""
ROOT_SECRET_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint) S3_ENDPOINT="${2:?--endpoint needs an address}"; shift 2 ;;
        -h|--help)  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/setup-rustfs.sh)"
    exit 1
fi
for tool in docker jq curl; do
    command -v "$tool" >/dev/null 2>&1 || { error "$tool is required"; exit 1; }
done

cleanup() {
    [[ -z "$POLICY_DIR" ]] || rm -rf "$POLICY_DIR"
    if [[ -n "$VAULT_TOKEN" ]]; then
        vault_header | curl -fsS -m "$VAULT_TIMEOUT_SECONDS" -X POST -H @- "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ── Vault ─────────────────────────────────────────────────────────────────────
# -H @- reads the header from stdin, the token stays out of the process list
vault_header() {
    printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN"
}

vault_errors() {
    jq -r '(.errors // []) | join("; ")' <<<"$1" 2>/dev/null || true
}

# vault_login: AppRole login (the same as in deploy.sh), sets VAULT_TOKEN
vault_login() {
    local file response
    for file in "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE"; do
        [[ -r "$file" ]] || { error "Vault login: $file is missing (README: Secrets from Vault)"; return 1; }
    done
    response=$(jq -n --rawfile role_id "$VAULT_ROLE_ID_FILE" --rawfile secret_id "$VAULT_SECRET_ID_FILE" \
        '{role_id: ($role_id | rtrimstr("\n")), secret_id: ($secret_id | rtrimstr("\n"))}' \
        | curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/auth/approle/login") \
        || { error "Vault login: $VAULT_ADDR is not reachable"; return 1; }
    VAULT_TOKEN=$(jq -r '.auth.client_token // empty' <<<"$response" 2>/dev/null)
    [[ -n "$VAULT_TOKEN" ]] || { error "Vault login refused: $(vault_errors "$response")"; return 1; }
}

# identity_keys <name>: "access_key secret_key" of docker/s3/<name> (the keys are letters and digits)
identity_keys() {
    local response
    response=$(vault_header | curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H @- "$VAULT_ADDR/v1/$VAULT_KV_MOUNT/data/s3/$1") \
        || { error "$1: $VAULT_ADDR is not reachable"; return 1; }
    jq -er '.data.data | select(.access_key and .secret_key) | "\(.access_key) \(.secret_key)"' <<<"$response" 2>/dev/null \
        || { error "$1: no keys in $VAULT_KV_MOUNT/s3/$1 ($(vault_errors "$response")). Run scripts/vault/create-s3-identities.ps1"; return 1; }
}

# ── Root key and tools ────────────────────────────────────────────────────────
# env_value <file> <name>: the last assignment of NAME in an env file, without quotes
env_value() {
    grep "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true
}

read_root_key() {
    ROOT_ACCESS_KEY=$(env_value "$ROOT_ENV_FILE" RUSTFS_ACCESS_KEY)
    ROOT_SECRET_KEY=$(env_value "$ROOT_ENV_FILE" RUSTFS_SECRET_KEY)
    [[ -n "$ROOT_ACCESS_KEY" && -n "$ROOT_SECRET_KEY" ]] \
        || { error "RUSTFS_ACCESS_KEY / RUSTFS_SECRET_KEY are missing in $ROOT_ENV_FILE"; return 1; }
}

# run_mc <mc arguments>: mc against RustFS as root. The credentials are in MC_HOST_rustfs (URL encoded), passed
# on by name, so they are not in the arguments of docker. The policy files are mounted read-only
run_mc() {
    local access secret scheme="${S3_ENDPOINT%%://*}" address="${S3_ENDPOINT#*://}"
    access=$(jq -rn --arg value "$ROOT_ACCESS_KEY" '$value | @uri')
    secret=$(jq -rn --arg value "$ROOT_SECRET_KEY" '$value | @uri')
    MC_HOST_rustfs="$scheme://$access:$secret@$address" \
        docker run --rm --network host -e MC_HOST_rustfs -v "$POLICY_DIR:/policies:ro" "$MC_IMAGE" "$@"
}

run_rclone() {
    RCLONE_CONFIG_RUSTFS_TYPE=s3 RCLONE_CONFIG_RUSTFS_PROVIDER=Other RCLONE_CONFIG_RUSTFS_ENDPOINT="$S3_ENDPOINT" \
    RCLONE_CONFIG_RUSTFS_ACCESS_KEY_ID="$ROOT_ACCESS_KEY" RCLONE_CONFIG_RUSTFS_SECRET_ACCESS_KEY="$ROOT_SECRET_KEY" \
        docker run --rm --network host -e RCLONE_CONFIG_RUSTFS_TYPE -e RCLONE_CONFIG_RUSTFS_PROVIDER -e RCLONE_CONFIG_RUSTFS_ENDPOINT \
            -e RCLONE_CONFIG_RUSTFS_ACCESS_KEY_ID -e RCLONE_CONFIG_RUSTFS_SECRET_ACCESS_KEY \
            "$RCLONE_IMAGE" "$@" --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s
}

wait_for_s3() {
    local attempt code
    for attempt in $(seq 1 "$WAIT_ATTEMPTS"); do
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$S3_ENDPOINT" || true)
        if [[ -n "$code" && "$code" != "000" ]]; then
            success "RustFS answers at $S3_ENDPOINT (HTTP $code)"
            return 0
        fi
        sleep "$WAIT_SECONDS"
    done
    error "RustFS does not answer at $S3_ENDPOINT. Deploy it: sudo scripts/docker/deploy.sh rustfs (docker logs rustfs)"
    return 1
}

# ── Buckets, policies, users ──────────────────────────────────────────────────
create_buckets() {
    local bucket
    for bucket in $(jq -r '.buckets[]' "$IDENTITIES_FILE"); do
        run_rclone mkdir "RUSTFS:$bucket" >/dev/null \
            || { error "Cannot create the bucket '$bucket' (wrong root key? see the message above)"; return 1; }
        success "Bucket '$bucket'"
    done
}

# policy_document <readwrite|read> <bucket>...: the IAM policy document of an identity
policy_document() {
    jq -n --arg access "$1" '
        $ARGS.positional as $buckets
        | ($buckets | map("arn:aws:s3:::\(.)")) as $containers
        | ($buckets | map("arn:aws:s3:::\(.)/*")) as $objects
        | {Version: "2012-10-17", Statement: (
            [{Effect: "Allow",
              Action: (if $access == "read" then ["s3:GetObject"]
                       else ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"] end),
              Resource: $objects},
             {Effect: "Allow", Action: ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"], Resource: $containers}]
            + (if $access == "read" then [{Effect: "Allow", Action: ["s3:ListAllMyBuckets"], Resource: ["arn:aws:s3:::*"]}] else [] end))}' \
        --args "${@:2}"
}

# apply_identity <name> <readwrite|read> <bucket>...: policy and user with the keys from Vault
apply_identity() {
    local name="$1" access="$2" keys user secret
    keys=$(identity_keys "$name") || return 1
    user="${keys%% *}"; secret="${keys#* }"
    policy_document "$access" "${@:3}" > "$POLICY_DIR/$name.json"
    run_mc admin policy create rustfs "$name" "/policies/$name.json" >/dev/null \
        || { error "$name: RustFS did not accept 'mc admin policy create' (see the message above)"; return 1; }
    run_mc admin user add rustfs "$user" "$secret" >/dev/null \
        || { error "$name: RustFS did not accept 'mc admin user add' (see the message above)"; return 1; }
    run_mc admin policy attach rustfs "$name" --user "$user" >/dev/null \
        || { error "$name: RustFS did not accept 'mc admin policy attach' (see the message above)"; return 1; }
    success "Identity '$name' ($access on ${*:3})"
}

apply_identities() {
    local entry failed=()
    while IFS= read -r entry; do
        # shellcheck disable=SC2046
        apply_identity $(jq -r '[.name, .access] + .buckets | join(" ")' <<<"$entry") || failed+=("$(jq -r .name <<<"$entry")")
    done < <(jq -c '.identities[]' "$IDENTITIES_FILE")
    [[ ${#failed[@]} -eq 0 ]] || { error "Failed: ${failed[*]}"; return 1; }
}

step "Reading the root key and the identities"
[[ -f "$IDENTITIES_FILE" ]] || { error "$IDENTITIES_FILE not found"; exit 1; }
read_root_key
POLICY_DIR=$(mktemp -d)
chmod 755 "$POLICY_DIR"
step "RustFS"
wait_for_s3
step "Buckets"
create_buckets
step "Vault login"
vault_login
success "Logged in at $VAULT_ADDR"
step "Policies and users"
apply_identities

echo
success "RustFS is prepared. The keys of an identity: vault kv get $VAULT_KV_MOUNT/s3/<name>"
info "Next: switch a client (endpoint $S3_ENDPOINT, the keys of its identity) and run it once."
