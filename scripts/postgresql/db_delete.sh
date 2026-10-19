#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <database_name>"
  exit 1
fi

DB_NAME=$1
DB_USER="${DB_NAME}_owner"

ROLE_RO="${DB_NAME}_role_ro"
ROLE_RW="${DB_NAME}_role_rw"
ROLE_OWNER="${DB_NAME}_role_owner"

echo "------------------------------------------"
echo "Starting cleanup for database: $DB_NAME"

psql_cmd() {
  sudo -u postgres psql "$@"
}

# Remove the partition maintenance job of audit_setup.sh, otherwise it fails every day (pg_cron
# keeps its jobs in its own database, not in the one that is dropped).
CRON_DATABASE=$(psql_cmd -tAc "SHOW cron.database_name" 2>/dev/null)
if [ -n "$CRON_DATABASE" ]; then
  psql_cmd -d "$CRON_DATABASE" -tAc "SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'audit-maintenance-$DB_NAME';" > /dev/null 2>&1
fi

psql_cmd -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();"

psql_cmd -c "DROP DATABASE IF EXISTS \"$DB_NAME\";"

USERS=$(psql_cmd -tAc "SELECT rolname FROM pg_roles WHERE rolname LIKE '${DB_NAME}_%' AND rolcanlogin = true;")

if [ -n "$USERS" ]; then
  echo "Found matching users to delete:"
  while read -r USER; do
    echo "  - $USER"
    psql_cmd -c "DROP USER IF EXISTS \"$USER\";"
  done <<< "$USERS"
else
  echo "No matching users found."
fi

psql_cmd -c "DROP ROLE IF EXISTS \"$ROLE_RO\", \"$ROLE_RW\", \"$ROLE_OWNER\";"

echo "Cleanup for $DB_NAME completed successfully."
