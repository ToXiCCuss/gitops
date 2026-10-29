#!/bin/bash
# =============================================================================
# backup-now.sh
# Runs the backups of the Docker host once, right now, and then the offsite sync to pCloud:
# vault-backup, restic-backup, offsite-sync (in this order, the sync last so that it copies the
# fresh data). Each step is "docker exec <container> sh <script> now", the same as the nightly run.
#
#   sudo scripts/docker/backup-now.sh [--background]
#
#   --background   detach from the terminal: the run goes on when the SSH session drops. Follow it with
#                  tail -f /var/log/backup-now.log
#
# Everything is also written to /var/log/backup-now.log (appended), so a run can be read afterwards.
# A failed step does not stop the others, the script exits with 1 and names the failed steps.
# Not covered: the NetBird server (sudo netbird_backup.sh on that host). Run it before this script
# if it should be in the sync.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

# container:script, in the order they run
STEPS=("vault-backup:/backup.sh" "restic-backup:/backup.sh" "offsite-sync:/sync.sh")
LOG_FILE="/var/log/backup-now.log"
FAILED=()

case "${1:-}" in
    "")           ;;
    --background) RUN_IN_BACKGROUND=1 ;;
    -h|--help)    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            error "Unknown argument: $1"; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (sudo scripts/docker/backup-now.sh)"
    exit 1
fi
command -v docker >/dev/null 2>&1 || { error "docker is required"; exit 1; }

if [[ -n "${RUN_IN_BACKGROUND:-}" ]]; then
    nohup "$0" >/dev/null 2>&1 &
    info "Started in the background (pid $!). Follow it with: tail -f $LOG_FILE"
    exit 0
fi

# From here on everything goes to the terminal and to the log file
exec > >(tee -a "$LOG_FILE") 2>&1
info "Run started $(date '+%Y-%m-%d %H:%M:%S')"

for entry in "${STEPS[@]}"; do
    container="${entry%%:*}"
    script="${entry#*:}"
    step "$container"
    started=$SECONDS
    if docker exec "$container" sh "$script" now; then
        success "$container finished after $((SECONDS - started))s"
    else
        error "$container failed after $((SECONDS - started))s (log: docker logs $container)"
        FAILED+=("$container")
    fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
    error "Failed: ${FAILED[*]}"
    exit 1
fi
success "Backups and offsite sync are done"
