#!/bin/bash
# =============================================================================
# setup-backup-host.sh
# Prepares the Docker host for the backup projects (restic-backup, offsite-sync).
# The projects are deployed with scripts/docker/deploy.sh.
#
#   sudo ./setup-backup-host.sh [--rclone-conf /root/.config/rclone/rclone.conf] [--dns 1.1.1.1] [--pcloud-remote pCloud]
#
# Creates the pCloud remote in rclone.conf if it is missing (token from `rclone authorize "pcloud"`), creates the
# data directories, installs rclone.conf for the offsite sync and checks the pCloud remote. The S3 (RustFS) with its
# buckets, users and keys is set up by scripts/docker/setup-rustfs.sh.
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
PCLOUD_REMOTE="pCloud"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
# Containers inherit the NetBird DNS (100.x) of the host, which they cannot reach: use a public resolver
DNS_SERVER="1.1.1.1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rclone-conf)      RCLONE_CONF="$2"; shift 2 ;;
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
mkdir -p "$DATA_ROOT"/restic-backup/{cache,restore,dump} "$DATA_ROOT/offsite-sync/rclone"
chmod 700 "$DATA_ROOT/offsite-sync/rclone" "$DATA_ROOT/restic-backup/dump"
success "Directories created below $DATA_ROOT"

# ── rclone.conf ───────────────────────────────────────────────────────────────
step "Installing rclone.conf"
install -m 600 "$RCLONE_CONF" "$DATA_ROOT/offsite-sync/rclone/rclone.conf"
success "$DATA_ROOT/offsite-sync/rclone/rclone.conf"

# ── pCloud check ──────────────────────────────────────────────────────────────
step "Checking the pCloud remote"
if docker run --rm --dns "$DNS_SERVER" -v "$DATA_ROOT/offsite-sync/rclone:/config/rclone:ro" "$RCLONE_IMAGE" \
        lsd "$PCLOUD_REMOTE:/" --timeout 30s --contimeout 15s --retries 1 --low-level-retries 1 >/dev/null; then
    success "pCloud remote works"
else
    error "Cannot list $PCLOUD_REMOTE:/ - check the error above: DNS/network, wrong region (eu/us) or an expired token"
    exit 1
fi

echo
success "Host is prepared. Next: set up RustFS (scripts/docker/setup-rustfs.sh), put the secrets of the projects into Vault (README) and deploy the projects with scripts/docker/deploy.sh."
