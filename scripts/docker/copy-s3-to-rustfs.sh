#!/bin/bash
# =============================================================================
# copy-s3-to-rustfs.sh
# Copies buckets from SeaweedFS to RustFS and compares them afterwards (rclone sync, then rclone check by size).
# For the move from SeaweedFS to RustFS: run it once for the first copy, and again for each bucket right before
# its writer is switched, so that the last backups are in RustFS. A restic repository is plain objects, so it is
# valid on RustFS as soon as every object is there. The target becomes a mirror of the source (objects that exist
# only in the target are removed).
#
#   sudo scripts/docker/copy-s3-to-rustfs.sh [--dry-run] [bucket ...]
#
# Without a bucket all buckets of docker/rustfs/identities.json are copied. SeaweedFS is read with the admin
# identity of /root/docker/seaweedfs-s3.json, RustFS is written with the root key of docker/rustfs/override.env.
# Do not run it while a backup writes to the bucket (the nightly runs are at 02:30, 03:00 and 05:00 UTC).
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IDENTITIES_FILE="$REPO_DIR/docker/rustfs/identities.json"
ROOT_ENV_FILE="$REPO_DIR/docker/rustfs/override.env"
SEAWEED_S3_CONFIG="/root/docker/seaweedfs-s3.json"
SEAWEED_ENDPOINT="http://127.0.0.1:8333"
RUSTFS_ENDPOINT="http://127.0.0.1:9000"
RCLONE_IMAGE="rclone/rclone:1.75.1"
SEAWEED_ADMIN_IDENTITY="admin"
TRANSFERS=4

DRY_RUN=()
BUCKETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=(--dry-run); shift ;;
        -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) error "Unknown argument: $1"; exit 1 ;;
        *)  BUCKETS+=("$1"); shift ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/copy-s3-to-rustfs.sh)"
    exit 1
fi
for tool in docker jq; do
    command -v "$tool" >/dev/null 2>&1 || { error "$tool is required"; exit 1; }
done

# env_value <file> <name>: the last assignment of NAME in an env file, without quotes
env_value() {
    grep "^$2=" "$1" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d "\"'" || true
}

# run_rclone <rclone arguments>: both S3 remotes are defined by environment variables, passed on by name so
# that the keys are not in the arguments of docker
run_rclone() {
    docker run --rm --network host \
        -e RCLONE_CONFIG_SOURCE_TYPE -e RCLONE_CONFIG_SOURCE_PROVIDER -e RCLONE_CONFIG_SOURCE_ENDPOINT \
        -e RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID -e RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY \
        -e RCLONE_CONFIG_TARGET_TYPE -e RCLONE_CONFIG_TARGET_PROVIDER -e RCLONE_CONFIG_TARGET_ENDPOINT \
        -e RCLONE_CONFIG_TARGET_ACCESS_KEY_ID -e RCLONE_CONFIG_TARGET_SECRET_ACCESS_KEY \
        "$RCLONE_IMAGE" "$@"
}

copy_bucket() {
    run_rclone sync "SOURCE:$1" "TARGET:$1" --s3-no-check-bucket --transfers "$TRANSFERS" --stats-one-line -v "${DRY_RUN[@]+"${DRY_RUN[@]}"}" \
        || { error "$1: the copy failed (see the message above)"; return 1; }
    [[ ${#DRY_RUN[@]} -gt 0 ]] || run_rclone check "SOURCE:$1" "TARGET:$1" --size-only --one-way \
        || { error "$1: the buckets differ after the copy (see the message above)"; return 1; }
    success "Bucket '$1' copied and compared"
}

[[ -f "$IDENTITIES_FILE" && -f "$SEAWEED_S3_CONFIG" ]] || { error "$IDENTITIES_FILE or $SEAWEED_S3_CONFIG is missing"; exit 1; }
[[ ${#BUCKETS[@]} -gt 0 ]] || mapfile -t BUCKETS < <(jq -r '.buckets[]' "$IDENTITIES_FILE")

export RCLONE_CONFIG_SOURCE_TYPE=s3 RCLONE_CONFIG_SOURCE_PROVIDER=SeaweedFS RCLONE_CONFIG_SOURCE_ENDPOINT="$SEAWEED_ENDPOINT"
RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID=$(jq -r --arg name "$SEAWEED_ADMIN_IDENTITY" '.identities[] | select(.name == $name) | .credentials[0].accessKey' "$SEAWEED_S3_CONFIG")
RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY=$(jq -r --arg name "$SEAWEED_ADMIN_IDENTITY" '.identities[] | select(.name == $name) | .credentials[0].secretKey' "$SEAWEED_S3_CONFIG")
export RCLONE_CONFIG_TARGET_TYPE=s3 RCLONE_CONFIG_TARGET_PROVIDER=Other RCLONE_CONFIG_TARGET_ENDPOINT="$RUSTFS_ENDPOINT"
RCLONE_CONFIG_TARGET_ACCESS_KEY_ID=$(env_value "$ROOT_ENV_FILE" RUSTFS_ACCESS_KEY)
RCLONE_CONFIG_TARGET_SECRET_ACCESS_KEY=$(env_value "$ROOT_ENV_FILE" RUSTFS_SECRET_KEY)
export RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID RCLONE_CONFIG_SOURCE_SECRET_ACCESS_KEY RCLONE_CONFIG_TARGET_ACCESS_KEY_ID RCLONE_CONFIG_TARGET_SECRET_ACCESS_KEY
[[ -n "$RCLONE_CONFIG_SOURCE_ACCESS_KEY_ID" && -n "$RCLONE_CONFIG_TARGET_ACCESS_KEY_ID" ]] \
    || { error "The admin key of $SEAWEED_S3_CONFIG or the root key of $ROOT_ENV_FILE is missing"; exit 1; }

FAILED=()
for bucket in "${BUCKETS[@]}"; do
    step "$bucket"
    copy_bucket "$bucket" || FAILED+=("$bucket")
done

echo
[[ ${#FAILED[@]} -eq 0 ]] || { error "Failed: ${FAILED[*]}"; exit 1; }
success "Done: ${BUCKETS[*]}"
