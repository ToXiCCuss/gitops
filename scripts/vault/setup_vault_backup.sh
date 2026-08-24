#!/bin/bash
# =============================================================================
# setup_vault_backup.sh
# Prepares the environment for Vault backups (vault_pb.sh).
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
divider() { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo ./setup_vault_backup.sh)"
        exit 1
    fi
}

check_debian() {
    if ! command -v apt-get &>/dev/null; then
        error "This script only supports Debian/Ubuntu (apt-get not found)"
        exit 1
    fi
}

print_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                Vault Backup Setup                        ║"
    echo "║          Preparation for vault_pb.sh                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

# ── 1. Install Vault ─────────────────────────────────────────────────────────
install_vault() {
    step "Install Vault CLI"

    if command -v vault &>/dev/null; then
        success "Vault CLI is already installed."
        return
    fi

    info "Installing dependencies (wget, gnupg)..."
    apt-get update -qq
    apt-get install -y wget gnupg

    info "Adding HashiCorp repository..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    
    info "Installing Vault..."
    apt-get update
    apt-get install -y vault

    if command -v vault &>/dev/null; then
        success "Vault CLI installed successfully."
    else
        error "Vault CLI installation failed."
        exit 1
    fi
}

# ── 2. Check Dependencies ─────────────────────────────────────────────────────
check_dependencies() {
    step "Checking dependencies"

    local missing=0

    if ! command -v vault &>/dev/null; then
        warn "Vault CLI not found even after installation attempt."
        missing=1
    else
        success "Vault CLI is available."
    fi

    if ! command -v restic &>/dev/null; then
        warn "restic is not installed. Please run scripts/linux/backup/setup_backup_tools.sh first."
        missing=1
    else
        success "restic is installed."
    fi

    if ! command -v rclone &>/dev/null; then
        warn "rclone is not installed. Please run scripts/linux/backup/setup_backup_tools.sh first."
        missing=1
    else
        success "rclone is installed."
    fi

    if [[ $missing -eq 1 ]]; then
        error "Some dependencies are missing. Please resolve them before proceeding."
        read -rp "Continue anyway? [y/N]: " CONT
        if [[ ! "$CONT" =~ ^[yY]$ ]]; then
            exit 1
        fi
    fi
}

# ── 3. Configure Vault Credentials ───────────────────────────────────────────
configure_vault() {
    step "Vault Configuration"
    
    local CONFIG_FILE="/etc/vault-backup.cred"
    
    if [[ -f "$CONFIG_FILE" ]]; then
        warn "Configuration file $CONFIG_FILE already exists."
        source "$CONFIG_FILE"
    fi

    read -rp "Vault Address [${VAULT_ADDR:-http://127.0.0.1:8200}]: " NEW_ADDR
    VAULT_ADDR=${NEW_ADDR:-${VAULT_ADDR:-http://127.0.0.1:8200}}

    echo -ne "Vault Backup Token: "
    read -s NEW_TOKEN
    echo ""
    VAULT_TOKEN=${NEW_TOKEN:-${VAULT_TOKEN:-}}

    if [[ -z "$VAULT_TOKEN" ]]; then
        error "Vault Token cannot be empty!"
        exit 1
    fi

    # Discord Settings
    echo -e "\nDiscord Notifications (Optional)"
    read -rp "Discord Webhook URL [${DISCORD_WEBHOOK_URL:-}]: " NEW_WEBHOOK
    DISCORD_WEBHOOK_URL=${NEW_WEBHOOK:-${DISCORD_WEBHOOK_URL:-}}

    read -rp "Discord User ID (for mentions) [${DISCORD_USER_ID:-}]: " NEW_USER_ID
    DISCORD_USER_ID=${NEW_USER_ID:-${DISCORD_USER_ID:-}}

    info "Saving configuration to $CONFIG_FILE..."
    cat > "$CONFIG_FILE" <<EOF
# Vault Backup Credentials
export VAULT_ADDR="$VAULT_ADDR"
export VAULT_TOKEN="$VAULT_TOKEN"
EOF

    if [[ -n "$DISCORD_WEBHOOK_URL" ]]; then
        echo "export DISCORD_WEBHOOK_URL=\"$DISCORD_WEBHOOK_URL\"" >> "$CONFIG_FILE"
    fi
    if [[ -n "$DISCORD_USER_ID" ]]; then
        echo "export DISCORD_USER_ID=\"$DISCORD_USER_ID\"" >> "$CONFIG_FILE"
    fi
    
    chmod 600 "$CONFIG_FILE"
    success "Configuration saved."
}

# ── 4. Prepare Backup Directory ──────────────────────────────────────────────
prepare_dir() {
    step "Preparing backup directory"
    local BACKUP_DIR="/var/backups/vault/physical"
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        info "Creating directory $BACKUP_DIR..."
        mkdir -p "$BACKUP_DIR"
        chmod 700 "/var/backups/vault"
    fi
    success "Backup directory is ready."
}

# ── 5. Initialize Restic Repository ──────────────────────────────────────────
init_restic() {
    step "Initialize Restic Repository"
    
    local REPO="rclone:pCloud:/Backups/vault_pb"
    local PW_FILE="/root/restic"

    if [[ ! -f "$PW_FILE" ]]; then
        error "Restic password file $PW_FILE not found!"
        info "Please run setup_backup_tools.sh to configure restic."
        return
    fi

    info "Checking repository: $REPO"
    if restic -r "$REPO" --password-file "$PW_FILE" snapshots &>/dev/null; then
        success "Repository already initialized."
    else
        info "Initializing repository..."
        if restic -r "$REPO" --password-file "$PW_FILE" init; then
            success "Repository initialized successfully."
        else
            error "Initialization failed. Check your rclone/pCloud configuration."
        fi
    fi
}

# ── 6. Setup Cronjob ─────────────────────────────────────────────────────────
setup_cron() {
    step "Setup Cronjob"
    
    local SCRIPT_PATH
    if command -v realpath &>/dev/null; then
        SCRIPT_PATH="$(realpath "$(dirname "$0")/vault_pb.sh")"
    else
        SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/vault_pb.sh"
    fi
    
    if [[ ! -f "$SCRIPT_PATH" ]]; then
        error "Backup script vault_pb.sh not found at $SCRIPT_PATH."
        return
    fi

    chmod +x "$SCRIPT_PATH"
    
    local RESTORE_SCRIPT_PATH
    if command -v realpath &>/dev/null; then
        RESTORE_SCRIPT_PATH="$(realpath "$(dirname "$0")/vault_restore.sh")"
    else
        RESTORE_SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/vault_restore.sh"
    fi
    [ -f "$RESTORE_SCRIPT_PATH" ] && chmod +x "$RESTORE_SCRIPT_PATH"

    local CRON_JOB="0 3 * * * /bin/bash $SCRIPT_PATH >> /var/log/vault_backup.log 2>&1"
    
    echo "Would you like to set up a daily cronjob (03:00 AM)?"
    read -rp "[y/N]: " ADD_CRON
    
    if [[ "$ADD_CRON" =~ ^[yY]$ ]]; then
        # Safely update crontab, handling empty crontab and avoiding pipefail issues
        local TMP_CRON
        TMP_CRON=$(mktemp)
        
        # Load existing crontab if available
        if crontab -l > "$TMP_CRON" 2>/dev/null; then
            # Remove existing job for this script to avoid duplicates
            # Use sed with a different delimiter to handle paths with slashes
            sed -i "\|$SCRIPT_PATH|d" "$TMP_CRON"
        else
            # Ensure file is empty if crontab -l failed
            : > "$TMP_CRON"
        fi
        
        # Append new job
        echo "$CRON_JOB" >> "$TMP_CRON"
        
        # Install new crontab
        if crontab "$TMP_CRON"; then
            success "Cronjob set up."
        else
            error "Failed to set up cronjob."
        fi
        
        rm -f "$TMP_CRON"
    else
        info "Skipped."
    fi
}

# ── 7. Setup Log Rotation ────────────────────────────────────────────────────
setup_logrotate() {
    step "Setup Log Rotation"
    
    local LOG_FILE="/var/log/vault_backup.log"
    local ROTATE_CONF="/etc/logrotate.d/vault-backup"
    
    if [[ ! -d "/etc/logrotate.d" ]]; then
        warn "logrotate directory not found. Skipping log rotation setup."
        return
    fi

    info "Creating logrotate configuration at $ROTATE_CONF..."
    
    cat > "$ROTATE_CONF" <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF

    # Ensure log file exists with correct permissions
    if [[ ! -f "$LOG_FILE" ]]; then
        touch "$LOG_FILE"
        chmod 640 "$LOG_FILE"
        # Try to set group to adm, but don't fail if it doesn't exist
        chown root:adm "$LOG_FILE" 2>/dev/null || true
    fi

    success "Log rotation set up (7 days retention)."
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_debian
    install_vault
    check_dependencies
    configure_vault
    prepare_dir
    init_restic
    setup_logrotate
    setup_cron
    
    divider
    success "Vault Backup Setup completed!"
    info "You can now test the backup manually with:  sudo $(dirname "$0")/vault_pb.sh"
    info "You can restore snapshots manually with:    sudo $(dirname "$0")/vault_restore.sh"
}

main "$@"
