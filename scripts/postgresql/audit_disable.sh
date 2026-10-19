#!/bin/bash

# Switches the audit off for tables of a database: removes the audit triggers. The rows already in
# audit.audit_log stay until the retention drops them.
#
# A table is given as name (schema public) or as schema.name.
#
# Usage: audit_disable.sh <database_name> <table> [table ...]

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

FUNCTION_FOUND=$(psql_cmd -d "$DB_NAME" -tAc "SELECT to_regprocedure('audit.disable_table(regclass)') IS NOT NULL" 2>/dev/null)
if [ "$FUNCTION_FOUND" != "t" ]; then
  echo "Error: no audit log in $DB_NAME. Nothing to switch off."
  exit 1
fi

echo "------------------------------------------"
echo "Audit off in database: $DB_NAME"

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

  if psql_cmd -d "$DB_NAME" -v ON_ERROR_STOP=1 -v schema_name="$SCHEMA_NAME" -v table_name="$TABLE_NAME" -q \
       <<< "SELECT audit.disable_table(format('%I.%I', :'schema_name', :'table_name')::regclass)" > /dev/null; then
    echo "  - $SCHEMA_NAME.$TABLE_NAME: audit off"
  else
    echo "  - $SCHEMA_NAME.$TABLE_NAME: failed (see the message above)"
  fi
done

echo "------------------------------------------"
