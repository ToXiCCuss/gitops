#!/bin/sh
# Nightly one-way sync SeaweedFS S3 -> pCloud. Deleted or overwritten files are moved to
# $PCLOUD_DELETED/<date> instead of being removed, so damage in the S3 does not reach pCloud for good.
set -u

export RCLONE_CONFIG_SEAWEED_TYPE=s3
export RCLONE_CONFIG_SEAWEED_PROVIDER=SeaweedFS
export RCLONE_CONFIG_SEAWEED_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

# Reports a failed run to the Discord webhook (optional). Successes are not reported.
notify_failure() {
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] && wget -q -O /dev/null --header 'Content-Type: application/json' \
        --post-data "{\"content\":\"offsite-sync failed: $1\"}" "$DISCORD_WEBHOOK_URL" || true
}

run_sync() {
    day=$(date +%Y-%m-%d)
    rclone sync "SEAWEED:" "$PCLOUD_REMOTE:$PCLOUD_TARGET" \
        --backup-dir "$PCLOUD_REMOTE:$PCLOUD_DELETED/$day" \
        --transfers 4 --checkers 4 --stats-one-line -v || return 1
    # Verify that everything in the S3 arrived in pCloud. S3 and pCloud have no hash in common,
    # so this compares the sizes (restic check on the pCloud repository verifies the content)
    rclone check "SEAWEED:" "$PCLOUD_REMOTE:$PCLOUD_TARGET" --one-way --size-only --checkers 4 || return 1
    # The folder only exists after the first file was overwritten or deleted
    rclone mkdir "$PCLOUD_REMOTE:$PCLOUD_DELETED" || return 1
    rclone delete "$PCLOUD_REMOTE:$PCLOUD_DELETED" --min-age "${RETENTION_DAYS}d" || return 1
    rclone rmdirs "$PCLOUD_REMOTE:$PCLOUD_DELETED" --leave-root || return 1
}

# One run right now and exit with its result (for tests): docker exec offsite-sync sh /sync.sh now
if [ "${1:-}" = "now" ]; then
    if run_sync; then
        echo "Sync finished"
        exit 0
    fi
    echo "Sync FAILED" >&2
    notify_failure sync-failed
    exit 1
fi

while true; do
    h=$(date +%H); m=$(date +%M); s=$(date +%S)
    now=$(( ${h#0} * 3600 + ${m#0} * 60 + ${s#0} ))
    target=$(( ${SYNC_HOUR#0} * 3600 + ${SYNC_MINUTE#0} * 60 ))
    wait=$(( (target - now + 86400) % 86400 ))
    echo "Next sync in ${wait}s"
    sleep "$wait"

    if run_sync; then
        echo "Sync finished"
    else
        echo "Sync FAILED" >&2
        notify_failure sync-failed
    fi
    sleep 60
done
