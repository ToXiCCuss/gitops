#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <database_name> <username>"
  exit 1
fi

DB_NAME=$1
USER_NAME="${DB_NAME}_$2"
NEW_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Resetting password for MariaDB user: $USER_NAME"
echo "New Password: $NEW_PASS"

sudo mariadb -e "ALTER USER '$USER_NAME'@'%' IDENTIFIED BY '$NEW_PASS'; FLUSH PRIVILEGES;"

if [ $? -eq 0 ]; then
  echo "Password updated successfully."
else
  echo "Error updating password."
fi
