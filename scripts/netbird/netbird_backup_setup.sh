#!/bin/bash
# =============================================================================
# netbird_backup_setup.sh
# Sets up netbird_backup.sh / netbird_restore.sh on the NetBird server:
#   - installs restic + rclone (if missing) and checks the pCloud remote
#   - creates the restic password file and initializes the repository
#   - writes /etc/netbird-backup.cred
#   - installs the backup/restore/upgrade/rollback scripts to /usr/local/bin
#     and a cron job
#
# Usage (run from the scripts/netbird directory):
#   sudo ./netbird_backup_setup.sh [--dir /opt/netbird] [--schedule "0 3 * * *"]
#                                  [--webhook URL] [--run]
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

RESTIC_REPOSITORY="rclone:pCloud:/Backups/netbird"
RESTIC_PASSWORD_FILE="/root/restic"
RCLONE_REMOTE="pCloud"

NETBIRD_DIR=""
SCHEDULE="0 3 * * *"
WEBHOOK=""
RUN_NOW=false

usage() {
    sed -n '11,13p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)      NETBIRD_DIR="$2"; shift 2 ;;
        --schedule) SCHEDULE="$2"; shift 2 ;;
        --webhook)  WEBHOOK="$2"; shift 2 ;;
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
    command -v rclone >/dev/null 2>&1 || missing+=(rclone)
    command -v curl   >/dev/null 2>&1 || missing+=(curl)

    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Installing: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}"
    fi
    success "restic $(restic version | awk '{print $2}'), rclone $(rclone version | awk 'NR==1{print $2}')"
}

# ── 3. rclone remote ──────────────────────────────────────────────────────────
check_rclone_remote() {
    step "Checking rclone remote '$RCLONE_REMOTE:'"

    if ! rclone listremotes | grep -qx "${RCLONE_REMOTE}:"; then
        error "rclone remote '$RCLONE_REMOTE' is not configured for root."
        info  "Run 'rclone config' as root and create a pCloud remote named '$RCLONE_REMOTE'."
        info  "On a headless server use 'rclone authorize \"pcloud\"' on a machine with a browser."
        exit 1
    fi
    if ! rclone lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1; then
        error "rclone remote '$RCLONE_REMOTE' is configured but not reachable (token expired?)."
        exit 1
    fi
    success "Remote '$RCLONE_REMOTE:' reachable."
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
write_config() {
    step "Writing $CONFIG_FILE"

    if [[ -f "$CONFIG_FILE" ]]; then
        # Keep existing values, only update what was passed / detected
        sed -i "s|^NETBIRD_DIR=.*|NETBIRD_DIR=\"$NETBIRD_DIR\"|" "$CONFIG_FILE"
        grep -q '^NETBIRD_DIR=' "$CONFIG_FILE" || echo "NETBIRD_DIR=\"$NETBIRD_DIR\"" >> "$CONFIG_FILE"
        if [[ -n "$WEBHOOK" ]]; then
            sed -i '/^DISCORD_WEBHOOK_URL=/d' "$CONFIG_FILE"
            echo "DISCORD_WEBHOOK_URL=\"$WEBHOOK\"" >> "$CONFIG_FILE"
        fi
        info "Updated existing config."
    else
        if [[ -z "$WEBHOOK" ]]; then
            read -rp "Discord webhook URL (empty = no notifications): " WEBHOOK
        fi
        (umask 077; cat > "$CONFIG_FILE" <<EOF
# NetBird backup settings - sourced by netbird_backup.sh / netbird_restore.sh
NETBIRD_DIR="$NETBIRD_DIR"
DISCORD_WEBHOOK_URL="$WEBHOOK"
#DISCORD_USER_ID="261598730027925505"
#RESTIC_REPOSITORY="$RESTIC_REPOSITORY"
#RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE"
#BACKUP_DIR="/var/backups/netbird"
#RESTIC_KEEP_DAILY=7
#RESTIC_KEEP_WEEKLY=4
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
    check_rclone_remote
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
