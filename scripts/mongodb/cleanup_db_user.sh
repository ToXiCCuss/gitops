#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <database_name>"
  exit 1
fi

DB_NAME=$1

# dropAllUsers on admin would remove the admin login of these scripts, the others are system databases.
case $DB_NAME in
  admin|local|config)
    echo "Error: $DB_NAME is a system database and cannot be cleaned up."
    exit 1
    ;;
esac

echo "------------------------------------------"
echo "Cleaning up Database: $DB_NAME"
echo "This will delete the database and all its users in this database."

CONFIG_FILE="/etc/mongodb-admin.cred"
AUTH_ARGS=""
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        AUTH_ARGS="-u $ADMIN_USER -p $ADMIN_PASS --authenticationDatabase admin"
    fi
fi

mongosh $AUTH_ARGS --quiet <<EOF
use $DB_NAME
// dropDatabase() keeps the users that were created in this database, so drop them first.
db.dropAllUsers()
db.dropDatabase()
EOF

if [ $? -eq 0 ]; then
  echo "Database $DB_NAME and its users have been deleted successfully."
else
  echo "Error during cleanup."
  exit 1
fi
