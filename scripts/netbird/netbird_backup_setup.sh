#!/bin/bash
# =============================================================================
# netbird_backup_setup.sh
# Sets up netbird_backup.sh / netbird_restore.sh on the NetBird server:
#   - installs restic (if missing) and checks the S3 of the Docker host
#   - creates the restic password file and initializes the repository
#   - writes /etc/netbird-backup.cred (S3 keys, optional Discord webhook URL)
#   - installs the backup/restore/upgrade/rollback scripts to /usr/local/bin
#     and a cron job
#
# Usage (run from the scripts/netbird directory):
#   sudo ./netbird_backup_setup.sh [--dir /opt/netbird] [--schedule "0 0 1 * *"]
#                                  [--s3-endpoint http://127.0.0.1:8333] [--discord-webhook URL]
#                                  [--run]
# The S3 keys (identity "netbird" of setup-backup-host.sh) are read from AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY or asked for. The schedule is in the local time of the host.
# Re-running is safe: existing password file, cred file and repository are kept.
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helper functions ──────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./netbird_backup_setup.sh)"
        exit 1
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/netbird-backup.cred"
CRON_FILE="/etc/cron.d/netbird-backup"
LOG_FILE="/var/log/netbird-backup.log"
INSTALL_DIR="/usr/local/bin"

S3_ENDPOINT="http://127.0.0.1:8333"
RESTIC_PASSWORD_FILE="/root/restic"
DISCORD_WEBHOOK_URL=""

NETBIRD_DIR=""
SCHEDULE="0 0 1 * *"
RUN_NOW=false

usage() {
    sed -n '11,16p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)      NETBIRD_DIR="$2"; shift 2 ;;
        --schedule) SCHEDULE="$2"; shift 2 ;;
        --s3-endpoint) S3_ENDPOINT="$2"; shift 2 ;;
        --discord-webhook) DISCORD_WEBHOOK_URL="$2"; shift 2 ;;
        --run)      RUN_NOW=true; shift ;;
        -h|--help)  usage 0 ;;
        *)          error "Unknown argument: $1"; usage 1 ;;
    esac
done

# ── 1. Locate NetBird install directory ───────────────────────────────────────
find_netbird_dir() {
    step "Locating NetBird installation"

    if [[ -z "$NETBIRD_DIR" && -f "$CONFIG_FILE" ]]; then
        NETBIRD_DIR=$(grep -oP '^NETBIRD_DIR="?\K[^"]*' "$CONFIG_FILE" || true)
    fi

    if [[ -z "$NETBIRD_DIR" ]]; then
        # Ask docker compose where the running NetBird project lives
        NETBIRD_DIR=$(docker ps --filter "label=com.docker.compose.service=netbird-server" \
                                --format '{{.Label "com.docker.compose.project.working_dir"}}' | head -n 1)
    fi
    if [[ -z "$NETBIRD_DIR" ]]; then
        NETBIRD_DIR=$(docker ps --filter "label=com.docker.compose.service=management" \
                                --format '{{.Label "com.docker.compose.project.working_dir"}}' | head -n 1)
    fi
    if [[ -z "$NETBIRD_DIR" ]]; then
        read -rp "NetBird install directory (contains docker-compose.yml): " NETBIRD_DIR
    fi

    if [[ ! -f "$NETBIRD_DIR/docker-compose.yml" ]]; then
        error "No docker-compose.yml in '$NETBIRD_DIR'."
        exit 1
    fi
    success "NetBird directory: $NETBIRD_DIR"
}

# ── 2. Dependencies ───────────────────────────────────────────────────────────
install_dependencies() {
    step "Checking dependencies"

    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        error "Docker with the compose plugin not found."
        exit 1
    fi

    local missing=()
    command -v restic >/dev/null 2>&1 || missing+=(restic)
    command -v curl   >/dev/null 2>&1 || missing+=(curl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    fi
    success "restic $(restic version | awk '{print $2}')"
}

# ── 3. S3 of the Docker host ──────────────────────────────────────────────────
check_s3() {
    step "Checking the S3 at $S3_ENDPOINT"

    RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/netbird/restic"

    # On a re-run take the keys of the existing configuration instead of asking again
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" && -f "$CONFIG_FILE" ]]; then
        AWS_ACCESS_KEY_ID=$(grep -m1 '^export AWS_ACCESS_KEY_ID=' "$CONFIG_FILE" | cut -d= -f2- | tr -d "\"'" || true)
        AWS_SECRET_ACCESS_KEY=$(grep -m1 '^export AWS_SECRET_ACCESS_KEY=' "$CONFIG_FILE" | cut -d= -f2- | tr -d "\"'" || true)
        [[ -z "$AWS_ACCESS_KEY_ID" ]] || info "Using the S3 keys of $CONFIG_FILE"
    fi
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        read -rp "S3 access key id of the identity 'netbird': " AWS_ACCESS_KEY_ID
    fi
    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        read -rsp "S3 secret access key: " AWS_SECRET_ACCESS_KEY
        echo ""
    fi
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    local code
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$S3_ENDPOINT" || true)
    if [[ "$code" == "000" || -z "$code" ]]; then
        error "S3 at $S3_ENDPOINT is not reachable. Is the seaweedfs project running?"
        exit 1
    fi
    success "S3 answers (HTTP $code)."
}

# ── 4. restic password + repository ───────────────────────────────────────────
setup_restic() {
    step "Setting up restic repository $RESTIC_REPOSITORY"

    if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
        read -rsp "Restic repository password (empty = generate one): " RESTIC_PW
        echo ""
        if [[ -z "$RESTIC_PW" ]]; then
            RESTIC_PW=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
            warn "Generated a new restic password in $RESTIC_PASSWORD_FILE."
            warn "Store it in your password manager - without it the backups are unreadable!"
        fi
        (umask 077; printf '%s\n' "$RESTIC_PW" > "$RESTIC_PASSWORD_FILE")
        unset RESTIC_PW
    else
        info "Using existing password file $RESTIC_PASSWORD_FILE."
    fi
    chmod 600 "$RESTIC_PASSWORD_FILE"

    if restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" cat config >/dev/null 2>&1; then
        success "Repository already initialized."
    else
        info "Initializing repository..."
        restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" init
        success "Repository initialized."
    fi
}

# ── 5. Config file ────────────────────────────────────────────────────────────
# set_cred <line prefix> <full line>: replaces a line of the config file or appends it
set_cred() {
    sed -i "\|^$1|d" "$CONFIG_FILE"
    echo "$2" >> "$CONFIG_FILE"
}

write_config() {
    step "Writing $CONFIG_FILE"

    if [[ -f "$CONFIG_FILE" ]]; then
        # Keep existing values, only update what was passed / detected
        sed -i "s|^NETBIRD_DIR=.*|NETBIRD_DIR=\"$NETBIRD_DIR\"|" "$CONFIG_FILE"
        grep -q '^NETBIRD_DIR=' "$CONFIG_FILE" || echo "NETBIRD_DIR=\"$NETBIRD_DIR\"" >> "$CONFIG_FILE"
        set_cred "RESTIC_REPOSITORY=" "RESTIC_REPOSITORY=\"$RESTIC_REPOSITORY\""
        set_cred "export AWS_ACCESS_KEY_ID=" "export AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\""
        set_cred "export AWS_SECRET_ACCESS_KEY=" "export AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\""
        if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
            set_cred "DISCORD_WEBHOOK_URL=" "DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\""
        fi
        info "Updated existing config."
    else
        (umask 077; cat > "$CONFIG_FILE" <<EOF
# NetBird backup settings - sourced by netbird_backup.sh / netbird_restore.sh
NETBIRD_DIR="$NETBIRD_DIR"
RESTIC_REPOSITORY="$RESTIC_REPOSITORY"
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"
DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
#RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
#BACKUP_DIR="/var/backups/netbird"
#RESTIC_KEEP_DAILY=0
#RESTIC_KEEP_WEEKLY=8
#RESTIC_KEEP_MONTHLY=6
EOF
        )
        success "Config written."
    fi
    chmod 600 "$CONFIG_FILE"
}

# ── 6. Scripts + cron ─────────────────────────────────────────────────────────
install_scripts() {
    step "Installing scripts to $INSTALL_DIR"

    for script in netbird_backup.sh netbird_restore.sh netbird_upgrade.sh netbird_rollback.sh; do
        if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
            error "$script not found next to this setup script ($SCRIPT_DIR)."
            exit 1
        fi
        # strip CRLF in case the repo was checked out on Windows
        sed 's/\r$//' "$SCRIPT_DIR/$script" > "$INSTALL_DIR/$script"
        chmod 750 "$INSTALL_DIR/$script"
        success "Installed $INSTALL_DIR/$script"
    done
}

install_cron() {
    step "Installing cron job ($SCHEDULE)"

    cat > "$CRON_FILE" <<EOF
# NetBird backup - managed by netbird_backup_setup.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/root

$SCHEDULE root $INSTALL_DIR/netbird_backup.sh >> $LOG_FILE 2>&1
EOF
    chmod 644 "$CRON_FILE"

    cat > /etc/logrotate.d/netbird-backup <<EOF
$LOG_FILE {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
    success "Cron job: $CRON_FILE (log: $LOG_FILE)"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_root

    echo "----------------------------------------------------------------------"
    echo "NetBird Backup Setup"

    install_dependencies
    find_netbird_dir
    check_s3
    setup_restic
    write_config
    install_scripts
    install_cron

    if $RUN_NOW; then
        step "Running first backup (NetBird will be stopped briefly)"
        "$INSTALL_DIR/netbird_backup.sh" 2>&1 | tee -a "$LOG_FILE"
        restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" snapshots --tag netbird
    else
        info "Run a first backup with: $INSTALL_DIR/netbird_backup.sh"
    fi

    echo ""
    success "Setup complete."
}

main "$@"
