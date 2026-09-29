#!/bin/bash
# =============================================================================
# setup-backup-host.sh
# Prepares the Docker host for the backup projects (backrest, offsite-sync,
# databasus, seaweedfs). Deploying the projects themselves is done in Arcane.
#
#   sudo ./setup-backup-host.sh --rclone-conf ~/rclone.conf [--bucket backups]
#                               [--s3-endpoint http://127.0.0.1:8333]
#                               [--remove-duplicati /path/to/docker/duplicati]
#
# S3 credentials are read from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or
# prompted for. They are never written to disk.
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
BUCKET="backups"
S3_ENDPOINT="http://127.0.0.1:8333"
PCLOUD_REMOTE="pCloud"
RCLONE_CONF=""
DUPLICATI_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rclone-conf)      RCLONE_CONF="$2"; shift 2 ;;
        --bucket)           BUCKET="$2"; shift 2 ;;
        --s3-endpoint)      S3_ENDPOINT="$2"; shift 2 ;;
        --pcloud-remote)    PCLOUD_REMOTE="$2"; shift 2 ;;
        --remove-duplicati) DUPLICATI_DIR="$2"; shift 2 ;;
        *) error "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo ./setup-backup-host.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }
[[ -f "$RCLONE_CONF" ]] || { error "--rclone-conf <file> is required (rclone.conf with the $PCLOUD_REMOTE remote)"; exit 1; }
grep -q "^\[$PCLOUD_REMOTE\]" "$RCLONE_CONF" || { error "Remote [$PCLOUD_REMOTE] not found in $RCLONE_CONF"; exit 1; }

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
if docker run --rm -v "$DATA_ROOT/offsite-sync/rclone:/config/rclone:ro" "$RCLONE_IMAGE" lsd "$PCLOUD_REMOTE:/" >/dev/null; then
    success "pCloud remote works"
else
    error "Cannot list $PCLOUD_REMOTE:/ - the token in rclone.conf may be expired"
    exit 1
fi

# ── SeaweedFS bucket ──────────────────────────────────────────────────────────
step "Creating the S3 bucket '$BUCKET'"
if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then read -r -p "S3 access key id: " AWS_ACCESS_KEY_ID; fi
if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then read -r -s -p "S3 secret access key: " AWS_SECRET_ACCESS_KEY; echo; fi

s3_rclone() {
    docker run --rm --network host \
        -e RCLONE_CONFIG_SEAWEED_TYPE=s3 \
        -e RCLONE_CONFIG_SEAWEED_PROVIDER=SeaweedFS \
        -e RCLONE_CONFIG_SEAWEED_ENDPOINT="$S3_ENDPOINT" \
        -e RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
        -e RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
        "$RCLONE_IMAGE" "$@"
}

if s3_rclone mkdir "SEAWEED:$BUCKET" && s3_rclone lsd SEAWEED: | grep -qw "$BUCKET"; then
    success "Bucket '$BUCKET' exists on $S3_ENDPOINT"
else
    error "Cannot reach SeaweedFS S3 at $S3_ENDPOINT (is the project deployed? credentials correct?)"
    exit 1
fi

# ── Duplicati ─────────────────────────────────────────────────────────────────
if [[ -n "$DUPLICATI_DIR" ]]; then
    step "Stopping Duplicati"
    (cd "$DUPLICATI_DIR" && docker compose down)
    success "Duplicati stopped (its data stays in $DATA_ROOT/duplicati)"
fi

echo
success "Host is prepared. Next: set the secrets in Arcane and deploy backrest, databasus and offsite-sync."
info "Backrest repo: s3:$S3_ENDPOINT/$BUCKET/docker"
