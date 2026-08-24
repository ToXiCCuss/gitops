#!/bin/bash

# Notification Settings
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/1486656956281389096/Wa82GI8W-EhviU0X1vAjoef2qvDm_s0hsxIGeTTUDc_cq1jdGMgBQEVzM8XnoWUB2OQw}"
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
DISCORD_ERROR_TITLE="MongoDB Physical Backup"

CONFIG_FILE="/etc/mongodb-admin.cred"
AUTH_ARGS=""
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        AUTH_ARGS="-u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    fi
fi

RESTIC_REPOSITORY="rclone:pCloud:/Backups/mongodb_pb"
RESTIC_PASSWORD_FILE="/root/restic"

BACKUP_DIR="/var/backups/mongodb/physical"
MONGO_DATA_DIR="/var/lib/mongodb"

echo "----------------------------------------------------------------------"
echo "[INFO] Starting physical backup process..."
START_TIME=$(date +%s)

echo "[INFO] Locking MongoDB (fsyncLock)..."
mongosh $AUTH_ARGS --quiet --eval "db.fsyncLock()"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to lock MongoDB"
    send_discord_error "Failed to lock MongoDB"
    exit 1
fi

echo "[INFO] Creating local copy of data files..."
mkdir -p "$BACKUP_DIR/data"
rsync -a "$MONGO_DATA_DIR/" "$BACKUP_DIR/data/"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to copy data files"
    send_discord_error "Failed to copy data files"
    mongosh $AUTH_ARGS --quiet --eval "db.fsyncUnlock()"
    exit 1
fi

echo "[INFO] Unlocking MongoDB..."
mongosh $AUTH_ARGS --quiet --eval "db.fsyncUnlock()"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to unlock MongoDB"
    send_discord_error "Failed to unlock MongoDB"
    exit 1
fi

echo "[INFO] Starting Restic backup..."
if command -v restic >/dev/null 2>&1; then
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        backup "$BACKUP_DIR/data"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Restic backup failed"
        send_discord_error "Restic backup failed"
        exit 1
    fi
else
    echo "[WARN] Restic not found, skipping remote backup."
fi

rm -rf "$BACKUP_DIR/data"

END_TIME=$(date +%s)
DURATION_SECONDS=$((END_TIME - START_TIME))
DURATION=$(format_duration $DURATION_SECONDS)

echo "[INFO] Physical backup completed successfully in $DURATION."
send_notification "$DISCORD_ERROR_TITLE" "Backup completed successfully" "success" "$DURATION"

