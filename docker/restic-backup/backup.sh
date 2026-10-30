#!/bin/sh
# Nightly restic run on the local RustFS S3. All steps run one after the other in one run, so they
# never fight over the repository lock:
#   repository docker:        backup of the key files, forget, prune, check
#   repository databases:     logical dumps of PostgreSQL and MariaDB, forget, prune, check
#   repositories vault, netbird: check only (vault-backup and netbird_backup.sh write and prune them)
#   every repository:         stats, its size and snapshots as metrics
# Every step leaves its result for the node_exporter textfile collector, Prometheus alerts on it.
set -u

apk add --no-cache restic rclone curl jq postgresql-client mariadb-client >/dev/null || { echo "apk add failed" >&2; exit 1; }

. /common.sh

# Static files only: the data directories of running services are not consistent when copied (see the README).
# /userdata/docker and /userdata/gitops are mounted read-only by the compose file
KEY_FILES="/userdata/gitops /userdata/docker/offsite-sync/rclone/rclone.conf"
GITOPS_GIT_DIRECTORY=/userdata/gitops/.git
MAX_UNUSED=10%

# Scratch folder of the dumps (a bind mount of the compose file), emptied after every backup
DUMP_DIR=/dump
# Databases that are no data of the application: MariaDB internals (users are created by scripts/mariadb)
MARIADB_SKIPPED_DATABASES="information_schema performance_schema mysql sys"

# Mount of the textfile collector directory of the node_exporter, see docker-compose.yml
METRICS_DIR=/metrics
JOB_NAME=restic-backup

# Time of the newest snapshot, 0 without snapshots. The zone of the writer is ignored (fromdate cannot read offsets
# or nanoseconds): netbird_backup.sh may run in local time, a few hours do not matter for an age shown in days
NEWEST_SNAPSHOT_FILTER='map(.time[0:19] + "Z" | fromdate) | max // 0'

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

# run_step <repository> <step> <function>: runs the function with the repository as argument, records the result and returns it
run_step() {
    started=$(date +%s)
    echo "== $1: $2"
    if "$3" "$1"; then
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

# One group per engine (tag), so each keeps its own number of snapshots
forget_old_dumps() {
    restic forget --group-by tags --keep-daily "$DATABASES_KEEP_DAILY" --keep-weekly "$DATABASES_KEEP_WEEKLY" --keep-monthly "$DATABASES_KEEP_MONTHLY"
}

# dump_postgresql <directory>: globals (roles without passwords, tablespaces) and one plain SQL file per database.
# Database names are checked by scripts/postgresql/db_create.sh, so they are safe as words and file names.
# A failed dump is removed so that a truncated file never reaches a snapshot; the others are still dumped
dump_postgresql() {
    export PGHOST="$POSTGRES_HOST" PGPORT="$POSTGRES_PORT" PGUSER="$POSTGRES_USER" PGPASSWORD="$POSTGRES_PASSWORD"
    dump_status=0
    pg_dumpall --globals-only --no-role-passwords > "$1/globals.sql" || { rm -f "$1/globals.sql"; dump_status=1; }
    names=$(psql --no-psqlrc --tuples-only --no-align --dbname postgres \
        --command "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate") || return 1
    for name in $names; do
        pg_dump --dbname "$name" > "$1/$name.sql" || { echo "pg_dump of $name failed" >&2; rm -f "$1/$name.sql"; dump_status=1; }
    done
    return "$dump_status"
}

# dump_mariadb <directory>: one SQL file per database, consistent without locking (InnoDB, --single-transaction).
# The connection stays on the Docker bridge to the host, so TLS is off (the MariaDB 11 client would otherwise insist on a verified certificate)
dump_mariadb() {
    export MYSQL_PWD="$MARIADB_PASSWORD"
    dump_status=0
    names=$(mariadb --host "$MARIADB_HOST" --port "$MARIADB_PORT" --user "$MARIADB_USER" --skip-ssl \
        --batch --skip-column-names --execute "SHOW DATABASES") || return 1
    for name in $names; do
        case " $MARIADB_SKIPPED_DATABASES " in *" $name "*) continue ;; esac
        mariadb-dump --host "$MARIADB_HOST" --port "$MARIADB_PORT" --user "$MARIADB_USER" --skip-ssl \
            --single-transaction --routines --events --triggers "$name" > "$1/$name.sql" \
            || { echo "mariadb-dump of $name failed" >&2; rm -f "$1/$name.sql"; dump_status=1; }
    done
    return "$dump_status"
}

# backup_dumps <engine> <dump function>: dumps into a scratch folder first and backs up the files. A pipe into
# "restic backup --stdin" would be shorter, but /bin/sh has no pipefail: a dump that died halfway would be a
# snapshot that looks fine. The folder holds all data in plain text, so it is removed in every case
backup_dumps() {
    restic cat config >/dev/null 2>&1 || restic init || return 1
    directory="$DUMP_DIR/$1"
    rm -rf "$directory"
    mkdir -p "$directory" && chmod 700 "$directory" || return 1
    "$2" "$directory"
    dumps_complete=$?
    backup_complete=0
    if [ -n "$(ls -A "$directory")" ]; then
        restic backup "$directory" --tag "$1" || backup_complete=1
    fi
    rm -rf "$directory"
    [ "$dumps_complete" = 0 ] && [ "$backup_complete" = 0 ]
}

backup_postgresql() {
    backup_dumps postgresql dump_postgresql
}

backup_mariadb() {
    backup_dumps mariadb dump_mariadb
}

prune_unused_data() {
    restic prune --max-unused "$MAX_UNUSED"
}

check_repository() {
    restic check --read-data-subset "$CHECK_READ_DATA_SUBSET"
}

# write_repository_metrics <repository>: the size in the S3 (after deduplication and compression), the number of
# snapshots and the time of the newest one. Each value is read on its own, because /bin/sh has no pipefail
write_repository_metrics() {
    statistics=$(restic stats --mode raw-data --json) || return 1
    snapshots=$(restic snapshots --json) || return 1
    size=$(printf '%s' "$statistics" | jq -er '.total_size') || return 1
    snapshot_count=$(printf '%s' "$snapshots" | jq -er 'length') || return 1
    newest_snapshot=$(printf '%s' "$snapshots" | jq -er "$NEWEST_SNAPSHOT_FILTER") || return 1
    labels="repository=\"$1\""
    {
        printf 'restic_repository_size_bytes{%s} %s\n' "$labels" "$size"
        printf 'restic_repository_snapshots{%s} %s\n' "$labels" "$snapshot_count"
        printf 'restic_repository_newest_snapshot_timestamp_seconds{%s} %s\n' "$labels" "$newest_snapshot"
    } | publish_metrics "$JOB_NAME-$1-repository"
}

run_databases() {
    select_repository databases s3
    databases_backed_up=""
    run_step databases backup-postgresql backup_postgresql && databases_backed_up=1
    # MariaDB is optional: without a password in Vault there is no step
    if [ -n "${MARIADB_PASSWORD:-}" ]; then
        run_step databases backup-mariadb backup_mariadb && databases_backed_up=1
    fi
    if [ -n "$databases_backed_up" ]; then
        run_step databases forget forget_old_dumps
        run_step databases prune prune_unused_data
    fi
    run_step databases check check_repository
    run_step databases stats write_repository_metrics
}

run_nightly() {
    run_started=$(date +%s)
    FAILED_STEPS=""
    select_repository docker s3
    # Without a new snapshot there is nothing to thin out, check still runs
    if run_step docker backup backup_key_files; then
        run_step docker forget forget_old_snapshots
        run_step docker prune prune_unused_data
    fi
    run_step docker check check_repository
    run_step docker stats write_repository_metrics
    run_databases
    for repository in vault netbird; do
        select_repository "$repository" s3
        run_step "$repository" check check_repository
        run_step "$repository" stats write_repository_metrics
    done
    [ -z "$FAILED_STEPS" ] || return 1
    write_run_metrics "$run_started"
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
