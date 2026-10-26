#!/usr/bin/env bash
# Switches the audit on for tables of a database: AFTER INSERT/UPDATE/DELETE triggers write the old
# and new values to audit_log. Existing audit triggers of a table are replaced, so run it again
# after a column was added or removed. Run audit_setup.sh for the database first.
#
# The record id is the primary key. A table without one is audited with record_id NULL.
#
# Idempotent: a second run builds the same triggers again from the current columns. All tables are
# tried; if one fails, the script says which and ends with an error.
#
# Usage: audit_enable.sh [--dry-run] <database_name> <table> [table ...]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly MAX_IDENTIFIER_LENGTH=64

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

# The names are validated against IDENTIFIER_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

require_audit_log() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$DB_NAME' AND ROUTINE_NAME = 'audit_create_triggers'")" ]] ||
    die "no audit log in $DB_NAME. Run audit_setup.sh $DB_NAME first"
}

# enable_table <table>: succeeds if the triggers are in place (or would be, with --dry-run)
enable_table() {
  local table=$1 outcome=created
  if ! [[ $table =~ $IDENTIFIER_PATTERN && ${#table} -le $MAX_IDENTIFIER_LENGTH ]]; then
    log "failed: $table: the table name may only contain letters, digits and underscores"
    return 1
  fi
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$DB_NAME' AND EVENT_OBJECT_TABLE = '$table' AND TRIGGER_NAME LIKE '%\_audit' LIMIT 1")" ]]; then
    outcome=updated
  fi
  if [[ -z "$(mariadb_admin -e "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '$DB_NAME' AND TABLE_NAME = '$table' AND COLUMN_KEY = 'PRI' LIMIT 1")" ]]; then
    log "note: $table has no primary key, record_id stays NULL"
  fi

  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: audit triggers of $table (not executed)"
  else
    mariadb_admin "$DB_NAME" -e "CALL audit_create_triggers('$table')" || {
      log "failed: $table (see the message above)"
      return 1
    }
    log "$outcome: audit triggers of $table"
  fi
}

main() {
  local table failed_tables=()
  parse_arguments "$@"
  require_commands sudo mariadb
  require_audit_log

  for table in "${TABLES[@]}"; do
    enable_table "$table" || failed_tables+=("$table")
  done
  ((${#failed_tables[@]} == 0)) || die "audit not switched on for: ${failed_tables[*]}"
}

main "$@"
