#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <full_username> OR $0 <database_name> <username_suffix>"
  exit 1
fi

if [ -z "$2" ]; then
  USER_NAME=$1
else
  USER_NAME="${1}_$2"
fi

USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Updating Password for User: $USER_NAME"
echo "New Password:              $USER_PASS"

sudo -u postgres psql -c "ALTER USER \"$USER_NAME\" WITH PASSWORD '$USER_PASS';"

if [ $? -eq 0 ]; then
  echo "Password for user '$USER_NAME' has been updated successfully."
  echo "MAKE SURE TO SAVE THE NEW PASSWORD: $USER_PASS"
else
  echo "Error: Failed to update password for user '$USER_NAME'."
  exit 1
fi
