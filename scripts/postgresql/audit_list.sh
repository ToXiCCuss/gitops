#!/usr/bin/env bash
# Shows the audit of a database: the tables with audit triggers, the retention, the maintenance job
# and the partitions of audit.audit_log with their size and approximate row count. Read only.
#
# Usage: audit_list.sh <database_name>
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly MAX_IDENTIFIER_LENGTH=63

DB_NAME=""

usage() {
  log "Usage: $0 <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  (($# == 1)) || usage
  DB_NAME=$1
  validate_pattern "database name" "$DB_NAME" "$MAX_IDENTIFIER_LENGTH" "$IDENTIFIER_PATTERN"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v db_name="$DB_NAME" "$@"
}

require_audit_log() {
  [[ $(psql_admin -d "$DB_NAME" --no-align --tuples-only <<<"SELECT to_regprocedure('audit.log_change()') IS NOT NULL") == t ]] ||
    die "no audit log in $DB_NAME. Run audit_setup.sh $DB_NAME first"
}

print_audited_tables() {
  echo "Tables with audit triggers:"
  psql_admin -d "$DB_NAME" <<'SQL'
SELECT n.nspname AS schema_name, c.relname AS table_name,
       string_agg(t.tgname, ', ' ORDER BY t.tgname) AS triggers
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE t.tgfoid = to_regprocedure('audit.log_change()') AND NOT t.tgisinternal
 GROUP BY n.nspname, c.relname
 ORDER BY n.nspname, c.relname;
SQL
}

print_retention() {
  echo "Retention:"
  psql_admin -d "$DB_NAME" <<'SQL'
SELECT retention, premake AS partitions_ahead FROM partman.part_config WHERE parent_table = 'audit.audit_log';
SQL
}

print_maintenance_job() {
  local cron_database
  echo "Maintenance job (pg_cron):"
  cron_database=$(psql_admin --no-align --tuples-only <<<"SELECT coalesce(current_setting('cron.database_name', true), '')")
  if [[ -z $cron_database ]]; then
    echo "  pg_cron is not loaded."
  elif [[ $(psql_admin -d "$cron_database" --no-align --tuples-only <<<"SELECT to_regclass('cron.job') IS NOT NULL") != t ]]; then
    echo "  the extension pg_cron is not created in $cron_database."
  else
    psql_admin -d "$cron_database" -v job_name="audit-maintenance-$DB_NAME" <<'SQL'
SELECT jobname, schedule, active FROM cron.job WHERE jobname = :'job_name';
SQL
  fi
}

print_partitions() {
  echo "Partitions of audit.audit_log:"
  psql_admin -d "$DB_NAME" <<'SQL'
SELECT c.relname AS partition_name, pg_size_pretty(pg_total_relation_size(c.oid)) AS size, pg_stat_get_live_tuples(c.oid) AS rows_estimate
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
 WHERE i.inhparent = to_regclass('audit.audit_log')
 ORDER BY c.relname;
SQL
}

main() {
  parse_arguments "$@"
  require_commands sudo psql
  require_audit_log

  echo "Audit of database: $DB_NAME"
  echo
  print_audited_tables
  print_retention
  print_maintenance_job
  print_partitions
}

main "$@"
