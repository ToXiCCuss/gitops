#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <database_name> <username_suffix>"
  exit 1
fi

DB_NAME=$1
USER_SUFFIX=$2
FULL_USER="${DB_NAME}_${USER_SUFFIX}"

echo "------------------------------------------"
echo "Starting deletion of user: $FULL_USER"
echo "Database context:          $DB_NAME"

# Check if the user exists
USER_EXISTS=$(sudo -u postgres psql -t -A -c "SELECT count(*) FROM pg_roles WHERE rolname = '$FULL_USER';")

if [ "$USER_EXISTS" -eq 0 ]; then
  echo "Error: User '$FULL_USER' does not exist."
  exit 1
fi

# Terminate sessions if the user is currently connected
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '$FULL_USER' AND pid <> pg_backend_pid();"

# Delete user
sudo -u postgres psql -d "$DB_NAME" -c "DROP USER \"$FULL_USER\";"

if [ $? -eq 0 ]; then
  echo "User '$FULL_USER' has been successfully deleted."
else
  echo "Error: Failed to delete user '$FULL_USER'."
  echo "Note: If the user owns objects, you might need to REASSIGN OWNED BY or DROP OWNED BY first."
  exit 1
fi
