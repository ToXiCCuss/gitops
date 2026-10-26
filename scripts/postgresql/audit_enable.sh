#!/usr/bin/env bash
# Switches the audit on for tables of a database: AFTER INSERT/UPDATE/DELETE triggers write the old
# and new row to audit.audit_log. Existing audit triggers of a table are replaced, so run it again
# after the primary key changed. Run audit_setup.sh for the database first.
#
# A table is given as name (schema public) or as schema.name. The record id is the primary key,
# a table without one is audited with record_id NULL.
#
# Idempotent: a second run builds the same triggers again. All tables are tried; if one fails, the
# script says which and ends with an error.
#
# Usage: audit_enable.sh [--dry-run] <database_name> <table> [table ...]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly TABLE_PATTERN='^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)?$'
readonly MAX_IDENTIFIER_LENGTH=63
readonly DEFAULT_SCHEMA="public"

DB_NAME=""
TABLES=()

usage() {
  log "Usage: $0 [--dry-run] <database_name> <table> [table ...]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  TABLES=("${POSITIONAL[@]:1}")
  validate_pattern "database name" "$DB_NAME" "$MAX_IDENTIFIER_LENGTH" "$IDENTIFIER_PATTERN"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -d "$DB_NAME" "$@"
}

require_audit_log() {
  [[ $(psql_admin --no-align --tuples-only <<<"SELECT to_regprocedure('audit.enable_table(regclass)') IS NOT NULL") == t ]] ||
    die "no audit log in $DB_NAME. Run audit_setup.sh $DB_NAME first"
}

# enable_table <table>: succeeds if the triggers are in place (or would be, with --dry-run)
enable_table() {
  local table=$1 schema_name table_name outcome=created result
  if ! [[ $table =~ $TABLE_PATTERN ]]; then
    log "failed: $table: use name or schema.name with letters, digits and underscores"
    return 1
  fi
  schema_name=$DEFAULT_SCHEMA
  table_name=$table
  if [[ $table == *.* ]]; then
    schema_name=${table%%.*}
    table_name=${table#*.}
  fi

  local variables=(-v "schema_name=$schema_name" -v "table_name=$table_name")
  if [[ $(psql_admin --no-align --tuples-only "${variables[@]}" <<<"SELECT to_regclass(format('%I.%I', :'schema_name', :'table_name')) IS NOT NULL") != t ]]; then
    log "failed: $schema_name.$table_name does not exist"
    return 1
  fi
  if [[ $(psql_admin --no-align --tuples-only "${variables[@]}" <<<"SELECT count(*) FROM pg_trigger WHERE tgrelid = format('%I.%I', :'schema_name', :'table_name')::regclass AND tgfoid = to_regprocedure('audit.log_change()') AND NOT tgisinternal") != 0 ]]; then
    outcome=updated
  fi

  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: audit triggers of $schema_name.$table_name (not executed)"
  else
    result=$(psql_admin --no-align --tuples-only "${variables[@]}" <<<"SELECT audit.enable_table(format('%I.%I', :'schema_name', :'table_name')::regclass)") || {
      log "failed: $schema_name.$table_name (see the message above)"
      return 1
    }
    log "$outcome: audit triggers of $schema_name.$table_name"
    if [[ $result == "no primary key" ]]; then
      log "note: $schema_name.$table_name has no primary key, record_id stays NULL"
    fi
  fi
}

main() {
  local table failed_tables=()
  parse_arguments "$@"
  require_commands sudo psql
  require_audit_log

  for table in "${TABLES[@]}"; do
    enable_table "$table" || failed_tables+=("$table")
  done
  ((${#failed_tables[@]} == 0)) || die "audit not switched on for: ${failed_tables[*]}"
}

main "$@"
