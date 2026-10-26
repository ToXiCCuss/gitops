#!/usr/bin/env bash
# Shows the audit of a database: the tables with audit triggers, the retention and the partitions
# of audit_log with their row counts. Read only.
#
# Usage: audit_list.sh <database_name>
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly IDENTIFIER_PATTERN='^[A-Za-z0-9_]+$'
readonly MAX_IDENTIFIER_LENGTH=64

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

# The name is validated against IDENTIFIER_PATTERN, so it can be put into the SQL directly
mariadb_admin() {
  sudo mariadb "$@"
}

print_audited_tables() {
  echo "Tables with audit triggers:"
  mariadb_admin -t -e "
SELECT EVENT_OBJECT_TABLE AS table_name,
       GROUP_CONCAT(EVENT_MANIPULATION ORDER BY EVENT_MANIPULATION SEPARATOR ', ') AS audited_operations
  FROM information_schema.TRIGGERS
 WHERE TRIGGER_SCHEMA = '$DB_NAME' AND TRIGGER_NAME LIKE '%\_audit'
 GROUP BY EVENT_OBJECT_TABLE
 ORDER BY EVENT_OBJECT_TABLE;"
}

print_maintenance_event() {
  echo
  echo "Maintenance event:"
  mariadb_admin -t -e "
SELECT EVENT_NAME AS event_name, STATUS AS status, EVENT_COMMENT AS retention, LAST_EXECUTED AS last_executed
  FROM information_schema.EVENTS
 WHERE EVENT_SCHEMA = '$DB_NAME' AND EVENT_NAME = 'audit_maintain_partitions';"
}

print_partitions() {
  echo
  echo "Partitions of audit_log:"
  mariadb_admin -t -e "
SELECT PARTITION_NAME AS partition_name, TABLE_ROWS AS approx_rows
  FROM information_schema.PARTITIONS
 WHERE TABLE_SCHEMA = '$DB_NAME' AND TABLE_NAME = 'audit_log'
 ORDER BY PARTITION_ORDINAL_POSITION;"
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb

  echo "Audit of database: $DB_NAME"
  echo
  print_audited_tables
  print_maintenance_event
  print_partitions
}

main "$@"
