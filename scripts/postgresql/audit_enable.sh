#!/bin/bash

# Switches the audit on for tables of a database: AFTER INSERT/UPDATE/DELETE triggers write the old
# and new row to audit.audit_log. Existing audit triggers of a table are replaced, so run it again
# after the primary key changed. Run audit_setup.sh for the database first.
#
# A table is given as name (schema public) or as schema.name. The record id is the primary key,
# a table without one is audited with record_id NULL.
#
# Usage: audit_enable.sh <database_name> <table> [table ...]

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <database_name> <table> [table ...]"
  exit 1
fi

DB_NAME="$1"
shift

DEFAULT_SCHEMA="public"

if [[ ! "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the database name may only contain letters, digits and underscores."
  exit 1
fi

psql_cmd() {
  sudo -u postgres psql "$@"
}

FUNCTION_FOUND=$(psql_cmd -d "$DB_NAME" -tAc "SELECT to_regprocedure('audit.enable_table(regclass)') IS NOT NULL" 2>/dev/null)
if [ "$FUNCTION_FOUND" != "t" ]; then
  echo "Error: no audit log in $DB_NAME. Run audit_setup.sh $DB_NAME first."
  exit 1
fi

echo "------------------------------------------"
echo "Audit on in database: $DB_NAME"

for TABLE in "$@"; do
  if [[ ! "$TABLE" =~ ^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)?$ ]]; then
    echo "  - $TABLE: skipped, use name or schema.name with letters, digits and underscores."
    continue
  fi

  if [[ "$TABLE" == *.* ]]; then
    SCHEMA_NAME="${TABLE%%.*}"
    TABLE_NAME="${TABLE#*.}"
  else
    SCHEMA_NAME="$DEFAULT_SCHEMA"
    TABLE_NAME="$TABLE"
  fi

  RESULT=$(psql_cmd -d "$DB_NAME" -v ON_ERROR_STOP=1 -v schema_name="$SCHEMA_NAME" -v table_name="$TABLE_NAME" -tA \
    <<< "SELECT audit.enable_table(format('%I.%I', :'schema_name', :'table_name')::regclass)")

  if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
    echo "  - $SCHEMA_NAME.$TABLE_NAME: audit on"
    if [ "$RESULT" = "no primary key" ]; then
      echo "    Note: no primary key, record_id stays NULL."
    fi
  else
    echo "  - $SCHEMA_NAME.$TABLE_NAME: failed (see the message above)"
  fi
done

echo "------------------------------------------"
