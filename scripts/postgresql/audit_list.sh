#!/bin/bash

# Shows the audit of a database: the tables with audit triggers, the retention, the maintenance job
# and the partitions of audit.audit_log with their size and approximate row count.
#
# Usage: audit_list.sh <database_name>

if [ -z "$1" ]; then
  echo "Usage: $0 <database_name>"
  exit 1
fi

DB_NAME="$1"

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the database name may only contain letters, digits and underscores."
  exit 1
fi

psql_cmd() {
  sudo -u postgres psql "$@"
}

echo "------------------------------------------"
echo "Audit of database: $DB_NAME"
echo
echo "Tables with audit triggers:"
psql_cmd -d "$DB_NAME" -c "
SELECT n.nspname AS schema_name, c.relname AS table_name,
       string_agg(t.tgname, ', ' ORDER BY t.tgname) AS triggers
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE t.tgfoid = to_regprocedure('audit.log_change()') AND NOT t.tgisinternal
 GROUP BY n.nspname, c.relname
 ORDER BY n.nspname, c.relname;"

echo "Retention:"
psql_cmd -d "$DB_NAME" -c "
SELECT retention, premake AS partitions_ahead FROM partman.part_config WHERE parent_table = 'audit.audit_log';" 2>/dev/null

echo "Maintenance job (pg_cron):"
CRON_DATABASE=$(psql_cmd -tAc "SHOW cron.database_name" 2>/dev/null)
if [ -n "$CRON_DATABASE" ]; then
  psql_cmd -d "$CRON_DATABASE" -v job_name="audit-maintenance-$DB_NAME" <<< "
SELECT jobname, schedule, active FROM cron.job WHERE jobname = :'job_name';" 2>/dev/null
else
  echo "  pg_cron is not loaded."
fi

echo "Partitions of audit.audit_log:"
psql_cmd -d "$DB_NAME" -c "
SELECT c.relname AS partition_name, pg_size_pretty(pg_total_relation_size(c.oid)) AS size, pg_stat_get_live_tuples(c.oid) AS rows_estimate
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
 WHERE i.inhparent = to_regclass('audit.audit_log')
 ORDER BY c.relname;" 2>/dev/null
echo "------------------------------------------"
