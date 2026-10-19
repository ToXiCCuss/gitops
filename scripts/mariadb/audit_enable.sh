#!/bin/bash

# Switches the audit on for tables of a database: AFTER INSERT/UPDATE/DELETE triggers write the old
# and new values to audit_log. Existing audit triggers of a table are replaced, so run it again
# after a column was added or removed. Run audit_setup.sh for the database first.
#
# The record id is the primary key. A table without one is audited with record_id NULL.
#
# Usage: audit_enable.sh <database_name> <table> [table ...]

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

PROCEDURE_FOUND=$(mariadb_cmd -N -B -e "SELECT 1 FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '$DB_NAME' AND ROUTINE_NAME = 'audit_create_triggers'")
if [ -z "$PROCEDURE_FOUND" ]; then
  echo "Error: no audit log in $DB_NAME. Run audit_setup.sh $DB_NAME first."
  exit 1
fi

echo "------------------------------------------"
echo "Audit on in database: $DB_NAME"

for TABLE_NAME in "$@"; do
  if [[ ! "$TABLE_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "  - $TABLE_NAME: skipped, the table name may only contain letters, digits and underscores."
    continue
  fi

  PRIMARY_KEY_FOUND=$(mariadb_cmd -N -B -e "SELECT 1 FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '$DB_NAME' AND TABLE_NAME = '$TABLE_NAME' AND COLUMN_KEY = 'PRI' LIMIT 1")

  if mariadb_cmd "$DB_NAME" -e "CALL audit_create_triggers('$TABLE_NAME')"; then
    echo "  - $TABLE_NAME: audit on"
    if [ -z "$PRIMARY_KEY_FOUND" ]; then
      echo "    Note: no primary key, record_id stays NULL."
    fi
  else
    echo "  - $TABLE_NAME: failed (see the message above)"
  fi
done

echo "------------------------------------------"
