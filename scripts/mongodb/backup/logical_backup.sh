#!/bin/bash


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

RESTIC_REPOSITORY="rclone:pCloud:/Backups/mongodb_lb"
RESTIC_PASSWORD_FILE="/root/restic"

BACKUP_DIR="/var/backups/mongodb/logical"

# --- Backup ------------------------------------------------------------------
echo "[INFO] Creating temporary backup folder..."
START_TIME=$(date +%s)
mkdir -p "$BACKUP_DIR/latest"

echo "[INFO] Starting mongodump..."
CONFIG_FILE="/etc/mongodb-admin.cred"
AUTH_ARGS=""
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        AUTH_ARGS="-u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    fi
fi

mongodump $AUTH_ARGS --out "$BACKUP_DIR/latest" --quiet

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to dump databases"
    exit 1
fi

echo "[INFO] Dump created in: $BACKUP_DIR/latest"

echo "[INFO] Starting Restic backup..."
if command -v restic >/dev/null 2>&1; then
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        backup "$BACKUP_DIR/latest"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Restic backup failed"
        exit 1
    fi
else
    echo "[WARN] Restic not found, skipping remote backup."
fi

rm -rf "$BACKUP_DIR/latest"
echo "[INFO] Local temporary dumps deleted."

END_TIME=$(date +%s)
DURATION_SECONDS=$((END_TIME - START_TIME))
DURATION=$(format_duration $DURATION_SECONDS)

echo "[INFO] Logical backup completed successfully in $DURATION."

