#!/bin/bash

# Switches the audit off for tables of a database: removes the audit triggers. The rows already in
# audit_log stay until the retention drops them.
#
# Usage: audit_disable.sh <database_name> <table> [table ...]

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <database_name> <table> [table ...]"
  exit 1
fi

DB_NAME="$1"
shift

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the database name may only contain letters, digits and underscores."
  exit 1
fi

mariadb_cmd() {
  sudo mariadb "$@"
}

PROCEDURE_FOUND=$(mariadb_cmd -N -B -e "SELECT 1 FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$DB_NAME' AND ROUTINE_NAME = 'audit_drop_triggers'")
if [ -z "$PROCEDURE_FOUND" ]; then
  echo "Error: no audit log in $DB_NAME. Nothing to switch off."
  exit 1
fi

echo "------------------------------------------"
echo "Audit off in database: $DB_NAME"

for TABLE_NAME in "$@"; do
  if [[ ! "$TABLE_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "  - $TABLE_NAME: skipped, the table name may only contain letters, digits and underscores."
    continue
  fi

  if mariadb_cmd "$DB_NAME" -e "CALL audit_drop_triggers('$TABLE_NAME')"; then
    echo "  - $TABLE_NAME: audit off"
  else
    echo "  - $TABLE_NAME: failed (see the message above)"
  fi
done

echo "------------------------------------------"
