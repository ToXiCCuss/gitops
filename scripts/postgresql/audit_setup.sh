#!/usr/bin/env bash
# Sets up the audit log of one database, or updates it if it exists. Run it once per database,
# then switch the audit on for single tables with audit_enable.sh.
#
# It creates in the database:
#   audit.audit_log      table, partitioned by month with pg_partman (plus a default partition)
#   audit.log_change     trigger function that writes the old and new row as JSON
#   audit.enable_table / audit.disable_table
#                        create and remove the triggers of one table
# and a daily pg_cron job (03:00, cron.timezone) that runs partman.run_maintenance(): it adds the
# partitions of the next months and drops the ones older than the retention.
#
# The audit schema is not readable for the application roles of db_create.sh, only for postgres and
# the Databasus backup role. The trigger function runs with the rights of its owner, so the
# application roles can write through it without access to the schema.
#
# Idempotent: running it again keeps the data of audit_log and reports what it created or changed.
# The retention is replaced by the given months, without months the current value is kept (first run: 6).
# A retention of 6 keeps the current month and the 6 before it.
#
# The job lives in the pg_cron database (cron.database_name, default postgres), not in the
# database itself. Run this script again after the database was restored from a dump, and
# db_delete.sh removes the job together with the database. Without pg_cron (not preloaded) the
# job is skipped with a warning, the default partition then catches every row and the log
# keeps working, only the partitions are not maintained.
#
# Usage: audit_setup.sh [--dry-run] <database_name> [retention_months]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly MAX_IDENTIFIER_LENGTH=63
readonly DEFAULT_RETENTION_MONTHS=6
readonly MAXIMUM_RETENTION_MONTHS=600
readonly PARTITIONS_AHEAD=3
readonly MAINTENANCE_SCHEDULE="0 3 * * *"
readonly MAINTENANCE_COMMAND="SELECT partman.run_maintenance()"

DB_NAME=""
RETENTION_MONTHS=""
CURRENT_RETENTION_MONTHS=""
JOB_NAME=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> [retention_months]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_pattern "database name" "$DB_NAME" "$MAX_IDENTIFIER_LENGTH" "$IDENTIFIER_PATTERN"
  JOB_NAME="audit-maintenance-$DB_NAME"
  if ((${#POSITIONAL[@]} == 2)); then
    [[ ${POSITIONAL[1]} =~ ^[0-9]+$ ]] || die "the retention must be a number of months between 1 and $MAXIMUM_RETENTION_MONTHS"
    RETENTION_MONTHS=$((10#${POSITIONAL[1]}))
    ((RETENTION_MONTHS >= 1 && RETENTION_MONTHS <= MAXIMUM_RETENTION_MONTHS)) ||
      die "the retention must be a number of months between 1 and $MAXIMUM_RETENTION_MONTHS"
  fi
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v db_name="$DB_NAME" "$@"
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
    psql_admin -d "$database" "$@" >/dev/null
    log "$outcome: $resource"
  fi
}

require_database() {
  [[ -n "$(query_value "SELECT 1 FROM pg_database WHERE datname = :'db_name'")" ]] ||
    die "database $DB_NAME does not exist"
}

# Without pg_partman there is no retention yet
resolve_retention() {
  if [[ $(query_value "SELECT to_regclass('partman.part_config') IS NOT NULL" -d "$DB_NAME") == t ]]; then
    CURRENT_RETENTION_MONTHS=$(query_value "SELECT regexp_replace(retention, '[^0-9]', '', 'g') FROM partman.part_config WHERE parent_table = 'audit.audit_log'" -d "$DB_NAME")
  fi
  RETENTION_MONTHS=${RETENTION_MONTHS:-${CURRENT_RETENTION_MONTHS:-$DEFAULT_RETENTION_MONTHS}}
  if [[ $CURRENT_RETENTION_MONTHS == "$RETENTION_MONTHS" ]]; then
    log "unchanged: retention $RETENTION_MONTHS months"
  else
    log "retention: ${CURRENT_RETENTION_MONTHS:-none} -> $RETENTION_MONTHS months"
  fi
}

# Everything in the block can be repeated without effect (IF NOT EXISTS, OR REPLACE, create_parent only
# when there is no parent yet), so it is applied on every run and a changed script reaches existing databases
apply_audit_objects() {
  local outcome=applied
  [[ $(query_value "SELECT to_regclass('audit.audit_log') IS NOT NULL" -d "$DB_NAME") == t ]] || outcome=created
  apply_sql "$DB_NAME" "$outcome" "audit schema, table audit.audit_log and its functions in $DB_NAME" \
    -v retention_months="$RETENTION_MONTHS" -v partitions_ahead="$PARTITIONS_AHEAD" <<'SQL'
SET client_min_messages = warning;

CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman SCHEMA partman;

CREATE SCHEMA IF NOT EXISTS audit;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;

CREATE TABLE IF NOT EXISTS audit.audit_log (
    id             bigint      GENERATED ALWAYS AS IDENTITY,
    schema_name    text        NOT NULL,
    table_name     text        NOT NULL,
    operation_type text        NOT NULL,
    record_id      text,
    old_data       jsonb,
    new_data       jsonb,
    timestamp      timestamptz NOT NULL DEFAULT now(),
    user_name      text        NOT NULL DEFAULT session_user,
    PRIMARY KEY (id, timestamp)
) PARTITION BY RANGE (timestamp);

CREATE INDEX IF NOT EXISTS audit_log_table_record ON audit.audit_log (table_name, record_id);

-- The record id is the primary key (several columns joined by "-"), the names come from the
-- trigger arguments that audit.enable_table sets. No arguments (no primary key): NULL.
CREATE OR REPLACE FUNCTION audit.log_change() RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit
AS $$
DECLARE
    v_row       jsonb;
    v_record_id text;
BEGIN
    v_row := to_jsonb(CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);

    IF TG_NARGS > 0 THEN
        SELECT string_agg(v_row ->> k.name, '-' ORDER BY k.position)
          INTO v_record_id
          FROM unnest(TG_ARGV) WITH ORDINALITY AS k(name, position);
    END IF;

    INSERT INTO audit.audit_log (schema_name, table_name, operation_type, record_id, old_data, new_data)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP, v_record_id,
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);

    RETURN NULL;
END;
$$;

-- Returns 'primary key' or 'no primary key' so the caller can tell the user.
CREATE OR REPLACE FUNCTION audit.enable_table(p_table regclass) RETURNS text
LANGUAGE plpgsql
SET search_path = pg_catalog, audit
AS $$
DECLARE
    v_schema   name;
    v_name     name;
    v_key_args text;
BEGIN
    SELECT n.nspname, c.relname INTO v_schema, v_name
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = p_table AND c.relkind IN ('r', 'p');

    IF NOT FOUND THEN
        RAISE EXCEPTION '% is not a table', p_table;
    END IF;
    IF v_schema IN ('audit', 'partman') THEN
        RAISE EXCEPTION 'tables of the schema % cannot be audited', v_schema;
    END IF;
    IF length(v_name) > 50 THEN
        RAISE EXCEPTION 'the table name is too long for the trigger names (50 characters at most)';
    END IF;

    SELECT string_agg(quote_literal(a.attname), ', ' ORDER BY k.position)
      INTO v_key_args
      FROM pg_index i
     CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, position)
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
     WHERE i.indrelid = p_table AND i.indisprimary;

    PERFORM audit.disable_table(p_table);

    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION audit.log_change(%s)',
                   v_name || '_audit_insert_delete', p_table, coalesce(v_key_args, ''));
    -- An UPDATE that changes no value writes nothing.
    EXECUTE format('CREATE TRIGGER %I AFTER UPDATE ON %s FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION audit.log_change(%s)',
                   v_name || '_audit_update', p_table, coalesce(v_key_args, ''));

    RETURN CASE WHEN v_key_args IS NULL THEN 'no primary key' ELSE 'primary key' END;
END;
$$;

CREATE OR REPLACE FUNCTION audit.disable_table(p_table regclass) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, audit
SET client_min_messages = warning
AS $$
DECLARE
    v_name name;
BEGIN
    SELECT relname INTO v_name FROM pg_class WHERE oid = p_table;

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_name || '_audit_insert_delete', p_table);
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', v_name || '_audit_update', p_table);
END;
$$;

REVOKE ALL ON FUNCTION audit.log_change() FROM PUBLIC;
REVOKE ALL ON FUNCTION audit.enable_table(regclass) FROM PUBLIC;
REVOKE ALL ON FUNCTION audit.disable_table(regclass) FROM PUBLIC;

SELECT partman.create_parent(p_parent_table => 'audit.audit_log',
                             p_control      => 'timestamp',
                             p_interval     => '1 month',
                             p_premake      => :partitions_ahead)
 WHERE NOT EXISTS (SELECT 1 FROM partman.part_config WHERE parent_table = 'audit.audit_log');

UPDATE partman.part_config
   SET retention = (:retention_months || ' months'),
       retention_keep_table = false,
       infinite_time_partitions = true
 WHERE parent_table = 'audit.audit_log';

SELECT partman.run_maintenance();
SQL
}

# The job is only written when it is missing or differs, pg_cron keeps jobs by their name
ensure_maintenance_job() {
  local cron_database job_found="" outcome=created
  cron_database=$(query_value "SELECT coalesce(current_setting('cron.database_name', true), '')")
  if [[ -z $cron_database ]]; then
    log "Warning: pg_cron is not loaded (shared_preload_libraries, set by the Ansible role postgresql, restart needed)."
    log "         The partitions are not maintained until it is."
  else
    # cron.job exists only after CREATE EXTENSION pg_cron, and a query on a missing table fails even in an unused branch
    if [[ $(query_value "SELECT to_regclass('cron.job') IS NOT NULL" -d "$cron_database") == t ]]; then
      job_found=$(query_value "SELECT string_agg(CASE WHEN schedule = :'schedule' AND command = :'command' AND database = :'db_name' AND active
                                                      THEN 'same' ELSE 'different' END, ',') FROM cron.job WHERE jobname = :'job_name'" \
        -d "$cron_database" -v job_name="$JOB_NAME" -v schedule="$MAINTENANCE_SCHEDULE" -v command="$MAINTENANCE_COMMAND")
    fi
    [[ -z $job_found ]] || outcome=updated
    if [[ $job_found == same ]]; then
      log "unchanged: pg_cron job $JOB_NAME ($MAINTENANCE_SCHEDULE) in $cron_database"
    else
      apply_sql "$cron_database" "$outcome" "pg_cron job $JOB_NAME ($MAINTENANCE_SCHEDULE) in $cron_database" \
        -v job_name="$JOB_NAME" -v schedule="$MAINTENANCE_SCHEDULE" -v command="$MAINTENANCE_COMMAND" <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule_in_database(:'job_name', :'schedule', :'command', :'db_name') > 0 AS scheduled;
SQL
    fi
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql
  require_database

  resolve_retention
  apply_audit_objects
  ensure_maintenance_job
  log "Audit log ready. Switch it on per table: audit_enable.sh $DB_NAME <table> [table ...]"
}

main "$@"
