#!/bin/bash
# =============================================================================
# restore.sh
# Browses and restores the restic repositories of the Docker host. It runs restic in the
# restic-backup container, which has the S3 keys and the passwords (project docker/restic-backup).
#
#   sudo scripts/docker/restore.sh [--from pcloud] snapshots <repository>
#   sudo scripts/docker/restore.sh [--from pcloud] files <repository> [snapshot]
#   sudo scripts/docker/restore.sh [--from pcloud] restore <repository> [snapshot] [--include <path>]
#
#   repository  docker (key files), vault (Raft snapshots) or netbird
#   snapshot    an id from "snapshots", default latest
#   --from      s3 (default, the local SeaweedFS) or pcloud (the copy of the offsite sync, for a lost S3)
#   --include   restores only this path of the snapshot (as in "files"), repeatable
#
# "restore" writes into a new folder /root/docker/restic-backup/restore/<repository>-<snapshot>-<time>,
# the only writable place. It never overwrites anything: move the files into place yourself.
# Restored key files hold secrets in plain text, delete the folder afterwards.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

CONTAINER="restic-backup"
CONTAINER_RESTORE_DIR="/restore"
HOST_RESTORE_DIR="/root/docker/restic-backup/restore"
SOURCE="s3"
COMMAND=""
REPOSITORY=""
SNAPSHOT="latest"
INCLUDES=()

usage() {
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)    SOURCE="${2:?--from needs s3 or pcloud}"; shift 2 ;;
        --include) INCLUDES+=(--include "${2:?--include needs a path}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        error "Unknown argument: $1"; exit 1 ;;
        *)
            if [[ -z "$COMMAND" ]]; then COMMAND="$1"
            elif [[ -z "$REPOSITORY" ]]; then REPOSITORY="$1"
            else SNAPSHOT="$1"
            fi
            shift ;;
    esac
done

if [[ -z "$COMMAND" || -z "$REPOSITORY" ]]; then
    usage >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/restore.sh)"
    exit 1
fi
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    error "The container $CONTAINER is not running. Deploy it: sudo scripts/docker/deploy.sh restic-backup"
    exit 1
fi

# run_restic <restic arguments>: restic against the selected repository, inside the container
run_restic() {
    docker exec "$CONTAINER" sh -c '. /common.sh && select_repository "$1" "$2" && shift 2 && exec restic "$@"' \
        restic "$REPOSITORY" "$SOURCE" "$@"
}

restore_snapshot() {
    local folder="$REPOSITORY-$SNAPSHOT-$(date +%Y%m%d-%H%M%S)"
    step "Restoring $REPOSITORY, snapshot $SNAPSHOT (from $SOURCE)"
    run_restic restore "$SNAPSHOT" --target "$CONTAINER_RESTORE_DIR/$folder" "${INCLUDES[@]}"
    success "Restored to $HOST_RESTORE_DIR/$folder"
    warn "Move the files into place, then delete the folder (it may hold secrets in plain text)"
}

case "$COMMAND" in
    snapshots) run_restic snapshots ;;
    files)     run_restic ls --long "$SNAPSHOT" ;;
    restore)   restore_snapshot ;;
    *)         error "Unknown command: $COMMAND (snapshots, files or restore)"; usage >&2; exit 1 ;;
esac
