#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <database_name>"
  exit 1
fi

DB_NAME=$1

ROLE_RO="${DB_NAME}_role_ro"
ROLE_RW="${DB_NAME}_role_rw"
ROLE_OWNER="${DB_NAME}_role_owner"

echo "------------------------------------------"
echo "Starting cleanup for MariaDB database: $DB_NAME"

mariadb_cmd() {
  sudo mariadb "$@"
}

# Drop the database (schema)
mariadb_cmd -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;"

# Find and drop users that start with DB_NAME_
# MariaDB users are stored in mysql.user
USERS=$(mariadb_cmd -N -s -e "SELECT CONCAT('\'', User, '\'@\'', Host, '\'') FROM mysql.user WHERE User LIKE '${DB_NAME}_%';")

if [ -n "$USERS" ]; then
  echo "Found matching users to delete:"
  while read -r USER; do
    echo "  - $USER"
    # Using eval to handle the quotes correctly in the drop command
    mariadb_cmd -e "DROP USER IF EXISTS $USER;"
  done <<< "$USERS"
else
  echo "No matching users found."
fi

# Drop roles
mariadb_cmd -e "DROP ROLE IF EXISTS '$ROLE_RO', '$ROLE_RW', '$ROLE_OWNER';"

echo "Cleanup for $DB_NAME completed successfully."
