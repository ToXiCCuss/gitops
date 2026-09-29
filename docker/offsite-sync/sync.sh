#!/bin/sh
# Nightly one-way sync SeaweedFS S3 -> pCloud. Deleted or overwritten files are moved to
# $PCLOUD_DELETED/<date> instead of being removed, so damage in the S3 does not reach pCloud for good.
set -u

export RCLONE_CONFIG_SEAWEED_TYPE=s3
export RCLONE_CONFIG_SEAWEED_PROVIDER=SeaweedFS
export RCLONE_CONFIG_SEAWEED_ENDPOINT="$S3_ENDPOINT"
export RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID"
export RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY"

push() {
    [ -n "${PUSH_URL:-}" ] && wget -q -O /dev/null "${PUSH_URL}?status=$1&msg=$2" || true
}

run_sync() {
    day=$(date +%Y-%m-%d)
    rclone sync "SEAWEED:" "$PCLOUD_REMOTE:$PCLOUD_TARGET" \
        --backup-dir "$PCLOUD_REMOTE:$PCLOUD_DELETED/$day" \
        --transfers 4 --checkers 4 --stats-one-line -v || return 1
    rclone delete "$PCLOUD_REMOTE:$PCLOUD_DELETED" --min-age "${RETENTION_DAYS}d" || return 1
    rclone rmdirs "$PCLOUD_REMOTE:$PCLOUD_DELETED" --leave-root || return 1
}

while true; do
    h=$(date +%H); m=$(date +%M); s=$(date +%S)
    now=$(( ${h#0} * 3600 + ${m#0} * 60 + ${s#0} ))
    target=$(( ${SYNC_HOUR#0} * 3600 + ${SYNC_MINUTE#0} * 60 ))
    wait=$(( (target - now + 86400) % 86400 ))
    echo "Next sync in ${wait}s"
    sleep "$wait"

    if run_sync; then
        echo "Sync finished"
        push up OK
    else
        echo "Sync FAILED" >&2
        push down sync-failed
    fi
    sleep 60
done
