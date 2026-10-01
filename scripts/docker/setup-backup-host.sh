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
# Generates the SeaweedFS S3 identities (admin, backrest, databasus, vault, offsite-sync) into
# /root/docker/seaweedfs-s3.json and the keys into /root/backup-credentials.env. Run it before
# deploying seaweedfs, then again afterwards to create the buckets (it is idempotent).
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
REGENERATE=""
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
step "Generating the SeaweedFS S3 identities"
S3_CONFIG="$DATA_ROOT/seaweedfs-s3.json"
CREDENTIALS_FILE="/root/backup-credentials.env"

gen_key() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

if [[ -f "$S3_CONFIG" && -f "$CREDENTIALS_FILE" && -z "$REGENERATE" ]]; then
    info "$S3_CONFIG exists, keeping it (use --regenerate-s3 to create new keys)"
else
    ADMIN_KEY=$(gen_key);     ADMIN_SECRET=$(gen_key)
    BACKREST_KEY=$(gen_key);  BACKREST_SECRET=$(gen_key)
    DATABASUS_KEY=$(gen_key); DATABASUS_SECRET=$(gen_key)
    VAULT_KEY=$(gen_key);     VAULT_SECRET=$(gen_key)
    SYNC_KEY=$(gen_key);      SYNC_SECRET=$(gen_key)

    umask 077
    cat > "$S3_CONFIG" <<JSON
{
  "identities": [
    {"name": "admin", "credentials": [{"accessKey": "$ADMIN_KEY", "secretKey": "$ADMIN_SECRET"}],
     "actions": ["Admin", "Read", "Write", "List", "Tagging"]},
    {"name": "backrest", "credentials": [{"accessKey": "$BACKREST_KEY", "secretKey": "$BACKREST_SECRET"}],
     "actions": ["Read:$BACKUP_BUCKET", "Write:$BACKUP_BUCKET", "List:$BACKUP_BUCKET",
                 "Read:$VAULT_BUCKET", "Write:$VAULT_BUCKET", "List:$VAULT_BUCKET"]},
    {"name": "databasus", "credentials": [{"accessKey": "$DATABASUS_KEY", "secretKey": "$DATABASUS_SECRET"}],
     "actions": ["Read:$DB_BUCKET", "Write:$DB_BUCKET", "List:$DB_BUCKET"]},
    {"name": "vault", "credentials": [{"accessKey": "$VAULT_KEY", "secretKey": "$VAULT_SECRET"}],
     "actions": ["Read:$VAULT_BUCKET", "Write:$VAULT_BUCKET", "List:$VAULT_BUCKET"]},
    {"name": "offsite-sync", "credentials": [{"accessKey": "$SYNC_KEY", "secretKey": "$SYNC_SECRET"}],
     "actions": ["Read", "List"]}
  ]
}
JSON
    cat > "$CREDENTIALS_FILE" <<ENV
# Generated by setup-backup-host.sh. Copy the values into the Arcane project environments
# (backrest, offsite-sync) and the Databasus storage, then delete this file.
ADMIN_ACCESS_KEY_ID=$ADMIN_KEY
ADMIN_SECRET_ACCESS_KEY=$ADMIN_SECRET
BACKREST_ACCESS_KEY_ID=$BACKREST_KEY
BACKREST_SECRET_ACCESS_KEY=$BACKREST_SECRET
DATABASUS_ACCESS_KEY_ID=$DATABASUS_KEY
DATABASUS_SECRET_ACCESS_KEY=$DATABASUS_SECRET
VAULT_ACCESS_KEY_ID=$VAULT_KEY
VAULT_SECRET_ACCESS_KEY=$VAULT_SECRET
OFFSITE_SYNC_ACCESS_KEY_ID=$SYNC_KEY
OFFSITE_SYNC_SECRET_ACCESS_KEY=$SYNC_SECRET
ENV
    umask 022
    success "Identities written to $S3_CONFIG (mounted by seaweedfs)"
    warn "Credentials are in $CREDENTIALS_FILE - copy them to Arcane, then delete the file"
    warn "SeaweedFS must be (re)started to load the new identities"
fi

# The seaweedfs container drops to the user "seaweed", root-only (600) would be "permission denied".
# The file stays inside /root, which is not accessible for other users of the host.
chmod 644 "$S3_CONFIG"

# ── Buckets ───────────────────────────────────────────────────────────────────
step "Creating the S3 buckets '$BACKUP_BUCKET', '$DB_BUCKET' and '$VAULT_BUCKET'"
# shellcheck disable=SC1090
source "$CREDENTIALS_FILE"

s3_rclone() {
    docker run --rm --network host \
        -e RCLONE_CONFIG_SEAWEED_TYPE=s3 \
        -e RCLONE_CONFIG_SEAWEED_PROVIDER=SeaweedFS \
        -e RCLONE_CONFIG_SEAWEED_ENDPOINT="$S3_ENDPOINT" \
        -e RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$ADMIN_ACCESS_KEY_ID" \
        -e RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$ADMIN_SECRET_ACCESS_KEY" \
        "$RCLONE_IMAGE" "$@"
}

if s3_rclone mkdir "SEAWEED:$BACKUP_BUCKET" && s3_rclone mkdir "SEAWEED:$DB_BUCKET" && s3_rclone mkdir "SEAWEED:$VAULT_BUCKET"; then
    success "Buckets exist on $S3_ENDPOINT"
else
    warn "SeaweedFS S3 at $S3_ENDPOINT is not reachable yet: deploy the seaweedfs project in Arcane, then run this script again"
    exit 0
fi

echo
success "Host is prepared. Next: set the secrets in Arcane and deploy backrest, databasus and offsite-sync."
info "Backrest repo: s3:$S3_ENDPOINT/$BACKUP_BUCKET/docker"
