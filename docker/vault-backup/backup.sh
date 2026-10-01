#!/bin/sh
# Nightly Raft snapshot of Vault -> restic repository vault/raft on the SeaweedFS S3.
# Logs in with a periodic token that is only allowed to read the snapshot (policy vault_snapshot)
# and renews it on every run, so it never expires while the backup runs.
set -u

apk add --no-cache curl jq restic >/dev/null || { echo "apk add failed" >&2; exit 1; }

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD
export RESTIC_REPOSITORY="s3:${S3_ENDPOINT}/vault/raft"

push() {
    # Uptime Kuma shows the URL with ?status=up&msg=OK&ping=, cut the query off, it is added here
    [ -n "${PUSH_URL:-}" ] && curl -fsS -m 10 "${PUSH_URL%%\?*}?status=$1&msg=$2" >/dev/null || true
}

run_backup() {
    snap="/tmp/vault-$(date +%Y%m%d-%H%M%S).snap"

    # Keep the periodic token alive
    curl -fsS -m 30 -X POST -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/auth/token/renew-self" >/dev/null || return 1

    curl -fsS -m 300 -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/storage/raft/snapshot" -o "$snap" || { rm -f "$snap"; return 1; }
    [ -s "$snap" ] || { echo "snapshot is empty" >&2; rm -f "$snap"; return 1; }

    restic cat config >/dev/null 2>&1 || restic init || { rm -f "$snap"; return 1; }
    restic backup --tag vault "$snap" || { rm -f "$snap"; return 1; }
    rm -f "$snap"
    restic forget --tag vault --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" --prune || return 1
}

# One run right now and exit with its result (for tests): docker exec vault-backup sh /backup.sh now
if [ "${1:-}" = "now" ]; then
    if run_backup; then
        echo "Backup finished"
        push up OK
        exit 0
    fi
    echo "Backup FAILED" >&2
    push down backup-failed
    exit 1
fi

while true; do
    h=$(date +%H); m=$(date +%M); s=$(date +%S)
    now=$(( ${h#0} * 3600 + ${m#0} * 60 + ${s#0} ))
    target=$(( ${BACKUP_HOUR#0} * 3600 + ${BACKUP_MINUTE#0} * 60 ))
    wait=$(( (target - now + 86400) % 86400 ))
    echo "Next backup in ${wait}s"
    sleep "$wait"

    if run_backup; then
        echo "Backup finished"
        push up OK
    else
        echo "Backup FAILED" >&2
        push down backup-failed
    fi
    sleep 60
done
