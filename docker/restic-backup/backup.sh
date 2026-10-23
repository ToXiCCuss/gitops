#!/bin/sh
# Nightly restic run on the local SeaweedFS S3. All steps run one after the other in one run, so they
# never fight over the repository lock:
#   repository docker:        backup of the key files, forget, prune, check
#   repositories vault, netbird: check only (vault-backup and netbird_backup.sh write and prune them)
# Every step leaves its result for the node_exporter textfile collector, Prometheus alerts on it.
set -u

apk add --no-cache restic rclone curl >/dev/null || { echo "apk add failed" >&2; exit 1; }

. /common.sh

# Static files only: the data directories of running services are not consistent when copied (see the README).
# /userdata/docker and /userdata/gitops are mounted read-only by the compose file
KEY_FILES="/userdata/gitops /userdata/docker/databasus/secret.key /userdata/docker/offsite-sync/rclone/rclone.conf /userdata/docker/seaweedfs-s3.json"
GITOPS_GIT_DIRECTORY=/userdata/gitops/.git
MAX_UNUSED=10%

# Mount of the textfile collector directory of the node_exporter, see docker-compose.yml
METRICS_DIR=/metrics
JOB_NAME=restic-backup

# The steps that failed in this run, "repository/step" separated by spaces
FAILED_STEPS=""

# Reports a failed run to the Discord webhook (optional). Successes are not reported.
notify_failure() {
    [ -n "${DISCORD_WEBHOOK_URL:-}" ] && curl -fsS -m 10 -H 'Content-Type: application/json' \
        -d "{\"content\":\"restic-backup failed:$1\"}" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

# publish_metrics <name>: writes stdin to <name>.prom under another name and moves it, so the
# node_exporter never reads a half written file
publish_metrics() {
    cat > "$METRICS_DIR/$1.prom.tmp" && mv "$METRICS_DIR/$1.prom.tmp" "$METRICS_DIR/$1.prom" \
        || echo "Writing the metrics failed" >&2
}

# last_success_of <file>: the time of the last success from the previous metrics file of a step, 0 if there is none
last_success_of() {
    previous=$(sed -n 's/^restic_step_last_success_timestamp_seconds{.*} //p' "$1" 2>/dev/null | head -n 1)
    echo "${previous:-0}"
}

# write_step_metrics <repository> <step> <1 if the step worked, else 0> <start time>
write_step_metrics() {
    finished=$(date +%s)
    last_success=$(last_success_of "$METRICS_DIR/$JOB_NAME-$1-$2.prom")
    [ "$3" = 1 ] && last_success=$finished
    labels="repository=\"$1\",step=\"$2\""
    {
        printf 'restic_step_success{%s} %s\n' "$labels" "$3"
        printf 'restic_step_last_success_timestamp_seconds{%s} %s\n' "$labels" "$last_success"
        printf 'restic_step_duration_seconds{%s} %s\n' "$labels" "$((finished - $4))"
    } | publish_metrics "$JOB_NAME-$1-$2"
}

# write_run_metrics <start time>: the heartbeat of a run in which every step worked. The Status dashboard and
# the rules BackupTooOld and BackupNeverReported read it like the ones of the other backup jobs
write_run_metrics() {
    finished=$(date +%s)
    {
        printf 'backup_last_success_timestamp_seconds{backup="%s"} %s\n' "$JOB_NAME" "$finished"
        printf 'backup_last_duration_seconds{backup="%s"} %s\n' "$JOB_NAME" "$((finished - $1))"
    } | publish_metrics "$JOB_NAME"
}

# run_step <repository> <step> <function>: runs the function, records the result and returns it
run_step() {
    started=$(date +%s)
    echo "== $1: $2"
    if "$3"; then
        write_step_metrics "$1" "$2" 1 "$started"
    else
        echo "Step $2 of $1 FAILED" >&2
        FAILED_STEPS="$FAILED_STEPS $1/$2"
        write_step_metrics "$1" "$2" 0 "$started"
        return 1
    fi
}

backup_key_files() {
    restic cat config >/dev/null 2>&1 || restic init || return 1
    # KEY_FILES is a list of paths without spaces, it must be split
    # shellcheck disable=SC2086
    restic backup $KEY_FILES --exclude "$GITOPS_GIT_DIRECTORY"
}

# One group for all snapshots: the repository only holds the snapshots of this job (and the older ones
# of Backrest, which age out with them)
forget_old_snapshots() {
    restic forget --group-by '' --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
}

prune_unused_data() {
    restic prune --max-unused "$MAX_UNUSED"
}

check_repository() {
    restic check --read-data-subset "$CHECK_READ_DATA_SUBSET"
}

run_nightly() {
    started=$(date +%s)
    FAILED_STEPS=""
    select_repository docker s3
    # Without a new snapshot there is nothing to thin out, check still runs
    if run_step docker backup backup_key_files; then
        run_step docker forget forget_old_snapshots
        run_step docker prune prune_unused_data
    fi
    run_step docker check check_repository
    for repository in vault netbird; do
        select_repository "$repository" s3
        run_step "$repository" check check_repository
    done
    [ -z "$FAILED_STEPS" ] || return 1
    write_run_metrics "$started"
}

run_and_report() {
    if run_nightly; then
        echo "Run finished"
    else
        echo "Run FAILED:$FAILED_STEPS" >&2
        notify_failure "$FAILED_STEPS"
        return 1
    fi
}

# One run right now and exit with its result (for tests): docker exec restic-backup sh /backup.sh now
if [ "${1:-}" = "now" ]; then
    run_and_report
    exit $?
fi

while true; do
    h=$(date +%H); m=$(date +%M); s=$(date +%S)
    now=$(( ${h#0} * 3600 + ${m#0} * 60 + ${s#0} ))
    target=$(( ${BACKUP_HOUR#0} * 3600 + ${BACKUP_MINUTE#0} * 60 ))
    wait=$(( (target - now + 86400) % 86400 ))
    echo "Next run in ${wait}s"
    sleep "$wait"

    run_and_report || true
    sleep 60
done
