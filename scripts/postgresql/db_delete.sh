#!/usr/bin/env bash
# Ensures the database <database_name> and everything db_create.sh made for it does not exist: the
# partition job of audit_setup.sh, the database, the logins that belong to its three roles and the roles.
#
# Idempotent: parts that are already gone are reported as unchanged, so an aborted run can be repeated.
# The data is deleted for good; use --dry-run first. The passwords in Vault stay, because the host may only
# write there: delete them as admin with
#   vault kv metadata delete databases/postgresql/<login>
#
# A login belongs to the database if it is a member of <db>_role_ro, _rw or _owner (not by its name, so
# the logins of a database called <db>_dev are not touched).
#
# Usage: db_delete.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 63 bytes of a PostgreSQL identifier
readonly MAX_NAME_LENGTH=52
readonly PROTECTED_DATABASES=(postgres template0 template1)

DB_NAME=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local protected
  parse_options "$@"
  ((${#POSITIONAL[@]} == 1)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  for protected in "${PROTECTED_DATABASES[@]}"; do
    [[ $DB_NAME != "$protected" ]] || die "$DB_NAME is a system database and cannot be deleted"
  done
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" "$@"
}

# query_value <sql> [psql arguments]: the result of the query, empty if there is no row
query_value() {
  local sql=$1
  shift
  psql_admin --no-align --tuples-only "$@" <<<"$sql"
}

# apply_sql <database> <outcome> <resource> [psql arguments]: runs the SQL from stdin, or only reports it with --dry-run
apply_sql() {
  local database=$1 outcome=$2 resource=$3
  shift 3
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    psql_admin -d "$database" "$@"
    log "$outcome: $resource"
  fi
}

# The job lives in the pg_cron database, not in the one that is dropped, and would fail every day afterwards
ensure_audit_job_absent() {
  local cron_database job_name="audit-maintenance-$DB_NAME"
  cron_database=$(query_value "SELECT current_setting('cron.database_name', true)")
  if [[ -n $cron_database ]] &&
    [[ $(query_value "SELECT to_regclass('cron.job') IS NOT NULL" -d "$cron_database") == t ]] &&
    [[ -n $(query_value "SELECT 1 FROM cron.job WHERE jobname = :'job_name'" -d "$cron_database" -v job_name="$job_name") ]]; then
    apply_sql "$cron_database" unscheduled "pg_cron job $job_name" -v job_name="$job_name" <<<"SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = :'job_name';" >/dev/null
  else
    log "unchanged: no pg_cron job $job_name"
  fi
}

ensure_database_absent() {
  if [[ -n $(query_value "SELECT 1 FROM pg_database WHERE datname = :'db_name'") ]]; then
    apply_sql postgres terminated "sessions on $DB_NAME" <<<"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db_name' AND pid <> pg_backend_pid();" >/dev/null
    apply_sql postgres dropped "database $DB_NAME" <<<'DROP DATABASE :"db_name";'
  else
    log "unchanged: database $DB_NAME does not exist"
  fi
}

# The logins that are members of one of the three roles of the database
ensure_logins_absent() {
  local logins login
  logins=$(query_value "
    SELECT DISTINCT r.rolname
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.member
    JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolcanlogin AND NOT r.rolsuper AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')
    ORDER BY r.rolname")
  if [[ -z $logins ]]; then
    log "unchanged: no logins of $DB_NAME"
  else
    while read -r login; do
      apply_sql postgres dropped "login $login (its Vault entry stays)" -v drop_login="$login" <<<'DROP ROLE :"drop_login";'
    done <<<"$logins"
  fi
}

ensure_role_absent() {
  if [[ -n $(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'$1'") ]]; then
    apply_sql postgres dropped "role $2" <<<"DROP ROLE :\"$1\";"
  else
    log "unchanged: role $2 does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql

  ensure_audit_job_absent
  ensure_database_absent
  ensure_logins_absent
  ensure_role_absent role_ro "$ROLE_RO"
  ensure_role_absent role_rw "$ROLE_RW"
  ensure_role_absent role_owner "$ROLE_OWNER"
  log "Done: $DB_NAME"
}

main "$@"
