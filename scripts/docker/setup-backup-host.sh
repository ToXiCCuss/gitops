#!/bin/bash
# =============================================================================
# setup-backup-host.sh
# Prepares the Docker host for the backup projects (backrest, offsite-sync,
# databasus, seaweedfs). Deploying the projects themselves is done in Arcane.
#
#   sudo ./setup-backup-host.sh [--rclone-conf /root/.config/rclone/rclone.conf] [--regenerate-s3]
#                               [--s3-endpoint http://127.0.0.1:8333] [--dns 1.1.1.1]
#
# Creates the pCloud remote in rclone.conf if it is missing (token from `rclone authorize "pcloud"`).
# Maintains the SeaweedFS S3 identities (admin, backrest, databasus, vault, pelican, netbird, arcane, offsite-sync) in
# /root/docker/seaweedfs-s3.json and writes the keys of NEW identities to /root/backup-credentials.env.
# Existing keys are never changed (rights of existing identities are kept up to date), so new ones (and buckets) can be added at any time;
# --regenerate-s3 starts over with new keys for all. Needs jq. Run it before deploying seaweedfs,
# then again afterwards to create the buckets (it is idempotent).
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

RCLONE_IMAGE="rclone/rclone:1.75.1"
DATA_ROOT="/root/docker"
BACKUP_BUCKET="backups"
DB_BUCKET="databases"
VAULT_BUCKET="vault"
PELICAN_BUCKET="pelican"
NETBIRD_BUCKET="netbird"
ARCANE_BUCKET="arcane"
REGENERATE=""
NEW_KEYS=""
S3_CHANGED=""
S3_ENDPOINT="http://127.0.0.1:8333"
PCLOUD_REMOTE="pCloud"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
# Containers inherit the NetBird DNS (100.x) of the host, which they cannot reach: use a public resolver
DNS_SERVER="1.1.1.1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rclone-conf)      RCLONE_CONF="$2"; shift 2 ;;
        --regenerate-s3)    REGENERATE=1; shift ;;
        --s3-endpoint)      S3_ENDPOINT="$2"; shift 2 ;;
        --dns)              DNS_SERVER="$2"; shift 2 ;;
        --pcloud-remote)    PCLOUD_REMOTE="$2"; shift 2 ;;
        *) error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo ./setup-backup-host.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }

# ── pCloud remote ─────────────────────────────────────────────────────────────
step "Checking the pCloud remote in $RCLONE_CONF"
if [[ -f "$RCLONE_CONF" ]] && grep -q "^\[$PCLOUD_REMOTE\]" "$RCLONE_CONF"; then
    info "Remote [$PCLOUD_REMOTE] exists, keeping it"
else
    info "Remote [$PCLOUD_REMOTE] not found, creating it"
    info "pCloud needs a browser login. On a machine with a browser and rclone run: rclone authorize \"pcloud\""
    if [[ -z "${PCLOUD_HOSTNAME:-}" ]]; then
        read -r -p "pCloud data region (eu/us) [eu]: " region
        case "${region:-eu}" in
            eu) PCLOUD_HOSTNAME="eapi.pcloud.com" ;;
            us) PCLOUD_HOSTNAME="api.pcloud.com" ;;
            *)  error "Unknown region: $region"; exit 1 ;;
        esac
    fi
    if [[ -z "${PCLOUD_TOKEN:-}" ]]; then
        read -r -s -p "Paste the token JSON printed by rclone authorize: " PCLOUD_TOKEN
        echo
    fi
    [[ "$PCLOUD_TOKEN" == *access_token* ]] || { error "That does not look like the token JSON from rclone authorize"; exit 1; }
    mkdir -p "$(dirname "$RCLONE_CONF")"
    (
        umask 077
        {
            echo
            echo "[$PCLOUD_REMOTE]"
            echo "type = pcloud"
            echo "hostname = $PCLOUD_HOSTNAME"
            echo "token = $PCLOUD_TOKEN"
        } >> "$RCLONE_CONF"
    )
    unset PCLOUD_TOKEN
    success "Remote [$PCLOUD_REMOTE] added to $RCLONE_CONF"
fi

# ── Directories ───────────────────────────────────────────────────────────────
step "Creating data directories"
mkdir -p "$DATA_ROOT"/backrest/{data,config,cache,rclone,restore} "$DATA_ROOT/offsite-sync/rclone" "$DATA_ROOT/databasus" "$DATA_ROOT/seaweedfs"
chmod 700 "$DATA_ROOT/backrest/rclone" "$DATA_ROOT/backrest/config" "$DATA_ROOT/offsite-sync/rclone"
success "Directories created below $DATA_ROOT"

# ── rclone.conf ───────────────────────────────────────────────────────────────
step "Installing rclone.conf"
for dir in "$DATA_ROOT/backrest/rclone" "$DATA_ROOT/offsite-sync/rclone"; do
    install -m 600 "$RCLONE_CONF" "$dir/rclone.conf"
    success "$dir/rclone.conf"
done

# ── pCloud check ──────────────────────────────────────────────────────────────
step "Checking the pCloud remote"
if docker run --rm --dns "$DNS_SERVER" -v "$DATA_ROOT/offsite-sync/rclone:/config/rclone:ro" "$RCLONE_IMAGE" \
        lsd "$PCLOUD_REMOTE:/" --timeout 30s --contimeout 15s --retries 1 --low-level-retries 1 >/dev/null; then
    success "pCloud remote works"
else
    error "Cannot list $PCLOUD_REMOTE:/ - check the error above: DNS/network, wrong region (eu/us) or an expired token"
    exit 1
fi

# ── SeaweedFS S3 identities ───────────────────────────────────────────────────
step "Preparing the SeaweedFS S3 identities"
S3_CONFIG="$DATA_ROOT/seaweedfs-s3.json"
CREDENTIALS_FILE="/root/backup-credentials.env"

command -v jq >/dev/null 2>&1 || { error "jq is required (apt install jq)"; exit 1; }

gen_key() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

if [[ -n "$REGENERATE" ]]; then
    warn "--regenerate-s3: all identities get new keys"
    rm -f "$S3_CONFIG" "$CREDENTIALS_FILE"
fi

umask 077
[[ -f "$S3_CONFIG" ]] || echo '{"identities": []}' > "$S3_CONFIG"
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    cat > "$CREDENTIALS_FILE" <<'ENV'
# Generated by setup-backup-host.sh. Copy the values into the Arcane project environments
# (backrest, offsite-sync, vault-backup) and the Databasus storage, then delete this file.
ENV
fi

# ensure_identity <name> <actions as JSON array>: creates the identity with new keys if it does not exist yet
ensure_identity() {
    local name="$1" actions="$2" key secret prefix
    if jq -e --arg n "$name" '.identities[] | select(.name == $n)' "$S3_CONFIG" >/dev/null; then
        # keep the keys, but bring the rights up to date (e.g. a new bucket for an existing identity)
        if [[ "$(jq -c --arg n "$name" '.identities[] | select(.name == $n) | .actions' "$S3_CONFIG")" != "$(echo "$actions" | jq -c .)" ]]; then
            jq --arg n "$name" --argjson a "$actions" '(.identities[] | select(.name == $n) | .actions) = $a' \
                "$S3_CONFIG" > "$S3_CONFIG.tmp" && mv "$S3_CONFIG.tmp" "$S3_CONFIG"
            S3_CHANGED=1
            success "Identity '$name': rights updated, keys unchanged"
        else
            info "Identity '$name' exists, keys unchanged"
        fi
        return
    fi
    key=$(gen_key); secret=$(gen_key)
    jq --arg n "$name" --arg k "$key" --arg s "$secret" --argjson a "$actions" \
        '.identities += [{name: $n, credentials: [{accessKey: $k, secretKey: $s}], actions: $a}]' \
        "$S3_CONFIG" > "$S3_CONFIG.tmp" && mv "$S3_CONFIG.tmp" "$S3_CONFIG"
    prefix=$(echo "$name" | tr 'a-z-' 'A-Z_')
    {
        echo "${prefix}_ACCESS_KEY_ID=$key"
        echo "${prefix}_SECRET_ACCESS_KEY=$secret"
    } >> "$CREDENTIALS_FILE"
    NEW_KEYS=1
    success "Identity '$name' created, keys are in $CREDENTIALS_FILE"
}

# bucket_actions <bucket>...: Read, Write and List on each bucket as a JSON array
bucket_actions() {
    jq -cn '[$ARGS.positional[] as $b | "Read:\($b)", "Write:\($b)", "List:\($b)"]' --args "$@"
}

ensure_identity admin '["Admin", "Read", "Write", "List", "Tagging"]'
ensure_identity backrest "$(bucket_actions "$BACKUP_BUCKET" "$VAULT_BUCKET" "$NETBIRD_BUCKET")"
ensure_identity databasus "$(bucket_actions "$DB_BUCKET")"
ensure_identity vault "$(bucket_actions "$VAULT_BUCKET")"
ensure_identity pelican "$(bucket_actions "$PELICAN_BUCKET")"
ensure_identity netbird "$(bucket_actions "$NETBIRD_BUCKET")"
ensure_identity arcane "$(bucket_actions "$ARCANE_BUCKET")"
ensure_identity offsite-sync '["Read", "List"]'
umask 022

if [[ -n "$NEW_KEYS" ]]; then
    warn "Copy the new keys from $CREDENTIALS_FILE to Arcane (and Databasus/Pelican/NetBird), then delete the file"
fi
if [[ -n "$NEW_KEYS" || -n "$S3_CHANGED" ]]; then
    warn "SeaweedFS must be (re)started to load the new identities and rights"
fi

# The seaweedfs container drops to the user "seaweed", root-only (600) would be "permission denied".
# The file stays inside /root, which is not accessible for other users of the host.
chmod 644 "$S3_CONFIG"

# ── Buckets ───────────────────────────────────────────────────────────────────
step "Creating the S3 buckets '$BACKUP_BUCKET', '$DB_BUCKET', '$VAULT_BUCKET', '$PELICAN_BUCKET', '$NETBIRD_BUCKET' and '$ARCANE_BUCKET'"

if [[ -n "$NEW_KEYS" || -n "$S3_CHANGED" ]]; then
    warn "New S3 identities or rights were created. Restart the seaweedfs container so that it loads them, then run this script again to create the buckets"
    exit 0
fi

ADMIN_ACCESS_KEY_ID=$(jq -r '.identities[] | select(.name == "admin") | .credentials[0].accessKey' "$S3_CONFIG")
ADMIN_SECRET_ACCESS_KEY=$(jq -r '.identities[] | select(.name == "admin") | .credentials[0].secretKey' "$S3_CONFIG")

s3_rclone() {
    docker run --rm --network host \
        -e RCLONE_CONFIG_SEAWEED_TYPE=s3 \
        -e RCLONE_CONFIG_SEAWEED_PROVIDER=SeaweedFS \
        -e RCLONE_CONFIG_SEAWEED_ENDPOINT="$S3_ENDPOINT" \
        -e RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$ADMIN_ACCESS_KEY_ID" \
        -e RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$ADMIN_SECRET_ACCESS_KEY" \
        "$RCLONE_IMAGE" "$@" --retries 1 --low-level-retries 1 --timeout 30s --contimeout 10s
}

for bucket in "$BACKUP_BUCKET" "$DB_BUCKET" "$VAULT_BUCKET" "$PELICAN_BUCKET" "$NETBIRD_BUCKET" "$ARCANE_BUCKET"; do
    if out=$(s3_rclone mkdir "SEAWEED:$bucket" 2>&1); then
        success "Bucket '$bucket' exists on $S3_ENDPOINT"
        continue
    fi

    echo "$out" | grep -E "ERROR|Failed" | tail -n 3 >&2 || true
    case "$out" in
        *"connection refused"*|*"connection reset"*|*"i/o timeout"*|*"no such host"*|*"EOF"*)
            warn "SeaweedFS S3 at $S3_ENDPOINT is not reachable: deploy or start the seaweedfs project in Arcane (check 'docker logs seaweedfs'), then run this script again"
            exit 0 ;;
        *InvalidAccessKeyId*|*SignatureDoesNotMatch*|*AccessDenied*)
            error "SeaweedFS does not accept the admin key of $CREDENTIALS_FILE: the server runs with other keys. Restart the seaweedfs container so that it reloads $S3_CONFIG; check that it is mounted as a file"
            exit 1 ;;
        *InvalidBucketName*)
            error "S3 rejected the bucket name '$bucket' (3 to 63 characters, lower case)"
            exit 1 ;;
        *)
            error "Cannot create the bucket '$bucket' on $S3_ENDPOINT, see the message above"
            exit 1 ;;
    esac
done

echo
success "Host is prepared. Next: set the secrets in Arcane and deploy backrest, databasus and offsite-sync."
info "Backrest repo: s3:$S3_ENDPOINT/$BACKUP_BUCKET/docker"
