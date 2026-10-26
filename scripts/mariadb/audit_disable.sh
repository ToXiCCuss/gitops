#!/usr/bin/env bash
# Switches the audit off for tables of a database: removes the audit triggers. The rows already in
# audit_log stay until the retention drops them.
#
# Idempotent: a table without audit triggers is reported as unchanged. All tables are tried; if one
# fails, the script says which and ends with an error.
#
# Usage: audit_disable.sh [--dry-run] <database_name> <table> [table ...]
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
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$DB_NAME' AND ROUTINE_NAME = 'audit_drop_triggers'")" ]] ||
    die "no audit log in $DB_NAME. Nothing to switch off"
}

# disable_table <table>: succeeds if the table has no audit triggers afterwards (or would not have, with --dry-run)
disable_table() {
  local table=$1
  if ! [[ $table =~ $IDENTIFIER_PATTERN && ${#table} -le $MAX_IDENTIFIER_LENGTH ]]; then
    log "failed: $table: the table name may only contain letters, digits and underscores"
    return 1
  fi

  if [[ -z "$(mariadb_admin -e "SELECT 1 FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = '$DB_NAME' AND EVENT_OBJECT_TABLE = '$table' AND TRIGGER_NAME LIKE '%\_audit' LIMIT 1")" ]]; then
    log "unchanged: $table has no audit triggers"
  elif [[ $DRY_RUN == true ]]; then
    log "[dry-run] dropped: audit triggers of $table (not executed)"
  else
    mariadb_admin "$DB_NAME" -e "CALL audit_drop_triggers('$table')" || {
      log "failed: $table (see the message above)"
      return 1
    }
    log "dropped: audit triggers of $table"
  fi
}

main() {
  local table failed_tables=()
  parse_arguments "$@"
  require_commands sudo mariadb
  require_audit_log

  for table in "${TABLES[@]}"; do
    disable_table "$table" || failed_tables+=("$table")
  done
  ((${#failed_tables[@]} == 0)) || die "audit not switched off for: ${failed_tables[*]}"
}

main "$@"
