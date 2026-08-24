#!/bin/bash

if [ -z "$1" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

USER_NAME=$1

echo "------------------------------------------"
echo "Deleting MariaDB User: $USER_NAME"

sudo mariadb -e "DROP USER IF EXISTS '$USER_NAME'@'%';"

if [ $? -eq 0 ]; then
  echo "User '$USER_NAME' deleted successfully."
else
  echo "Error deleting user."
fi
