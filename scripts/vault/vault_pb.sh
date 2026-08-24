#!/bin/bash

# Notification Settings
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/1507839616550699048/TokgwF1Zj2l81rnYmg7InwYB5SaZar4BWs4mF8ktPHjaxILRE_7OE9Ze3y7VOTRCMnlz}"
DISCORD_USER_ID="${DISCORD_USER_ID:-261598730027925505}"

format_duration() {
    local seconds=$1
    local h=$((seconds / 3600))
    local m=$((seconds % 3600 / 60))
    local s=$((seconds % 60))
    
    if [ $h -gt 0 ]; then
        echo "${h}h ${m}m ${s}s"
    elif [ $m -gt 0 ]; then
        echo "${m}m ${s}s"
    else
        echo "${s}s"
    fi
}

send_notification() {
    local title="$1"
    local message="$2"
    local type="${3:-error}"
    local duration="$4"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)

    if [ -n "$DISCORD_WEBHOOK_URL" ]; then
        local color=15158332
        local emoji="🚨"
        
        if [ "$type" == "success" ]; then
            color=3066993 # green
            emoji="✅"
        elif [ "$type" == "info" ]; then
            color=3447003 # blue
            emoji="ℹ️"
        fi

        local fields="[
            { \"name\": \"🖥️ Server\", \"value\": \"$hostname\", \"inline\": true },
            { \"name\": \"🕒 Time\", \"value\": \"$timestamp\", \"inline\": true }"
        
        if [ -n "$duration" ]; then
            fields+=", { \"name\": \"⏱️ Duration\", \"value\": \"$duration\", \"inline\": true }"
        fi
        fields+="]"

        curl -s -H "Content-Type: application/json" \
             -X POST \
             -d "{
                \"username\": \"Backups\",
                \"content\": \"<@${DISCORD_USER_ID}>\",
                \"embeds\": [{
                    \"title\": \"$emoji $title\",
                    \"description\": \"**$message**\",
                    \"color\": $color,
                    \"fields\": $fields
                }]
             }" \
             "$DISCORD_WEBHOOK_URL" > /dev/null
    fi
}

send_discord_error() {
    send_notification "${DISCORD_ERROR_TITLE:-Error}" "$1" "error"
}
DISCORD_ERROR_TITLE="Vault Physical Backup"

# Load authentication
CONFIG_FILE="/etc/vault-backup.cred"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

export VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
export VAULT_TOKEN=${VAULT_TOKEN}
# VAULT_TOKEN should be defined in CONFIG_FILE

RESTIC_REPOSITORY="rclone:pCloud:/Backups/vault_pb"
RESTIC_PASSWORD_FILE="/root/restic"

BACKUP_DIR="/var/backups/vault/physical"
SNAPSHOT_FILE="$BACKUP_DIR/vault_snapshot.snap"

echo "----------------------------------------------------------------------"
echo "[INFO] Starting Vault physical backup process..."
START_TIME=$(date +%s)

# 1. Ensure Backup Directory exists
mkdir -p "$BACKUP_DIR"

# 2. Create Raft Snapshot
# Note: For Vault backups using Raft, a snapshot is the standard way to create a consistent point-in-time backup.
echo "[INFO] Creating Vault Raft snapshot..."
vault operator raft snapshot save "$SNAPSHOT_FILE"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to create Vault snapshot"
    send_discord_error "Failed to create Vault snapshot"
    exit 1
fi

echo "[INFO] Vault snapshot created: $SNAPSHOT_FILE"

# 3. Restic backup
echo "[INFO] Starting Restic backup..."
if command -v restic >/dev/null 2>&1; then
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        backup "$SNAPSHOT_FILE"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Restic backup failed"
        send_discord_error "Restic backup failed"
        exit 1
    fi
else
    echo "[WARN] Restic not found, skipping remote backup."
fi

# 4. Cleanup local copy
rm -f "$SNAPSHOT_FILE"

END_TIME=$(date +%s)
DURATION_SECONDS=$((END_TIME - START_TIME))
DURATION=$(format_duration $DURATION_SECONDS)

echo "[INFO] Vault physical backup completed successfully in $DURATION."
send_notification "$DISCORD_ERROR_TITLE" "Backup completed successfully" "success" "$DURATION"

