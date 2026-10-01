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
    exit 1
fi

echo "[INFO] Creating local copy of data files..."
mkdir -p "$BACKUP_DIR/data"
rsync -a "$MONGO_DATA_DIR/" "$BACKUP_DIR/data/"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to copy data files"
    mongosh $AUTH_ARGS --quiet --eval "db.fsyncUnlock()"
    exit 1
fi

echo "[INFO] Unlocking MongoDB..."
mongosh $AUTH_ARGS --quiet --eval "db.fsyncUnlock()"

if [ $? -ne 0 ]; then
    echo "[ERROR] Failed to unlock MongoDB"
    exit 1
fi

echo "[INFO] Starting Restic backup..."
if command -v restic >/dev/null 2>&1; then
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        backup "$BACKUP_DIR/data"

    if [ $? -ne 0 ]; then
        echo "[ERROR] Restic backup failed"
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

