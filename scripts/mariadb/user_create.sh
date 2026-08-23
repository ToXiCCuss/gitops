#!/bin/bash

if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
  echo "Usage: $0 <database_name> <new_username> <role_type: ro|rw|owner>"
  exit 1
fi

DB_NAME=$1
NEW_USER="${DB_NAME}_$2"
ROLE_TYPE=$3

case $ROLE_TYPE in
  ro)
    TARGET_ROLE="${DB_NAME}_role_ro"
    ;;
  rw)
    TARGET_ROLE="${DB_NAME}_role_rw"
    ;;
  owner)
    TARGET_ROLE="${DB_NAME}_role_owner"
    ;;
  *)
    echo "Error: Invalid role type. Use 'ro', 'rw', or 'owner'."
    exit 1
    ;;
esac

USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Creating MariaDB User: $NEW_USER"
echo "Assigning Role:        $TARGET_ROLE"
echo "Password:              $USER_PASS"
echo "------------------------------------------"

mariadb_cmd() {
  sudo mariadb -u root -h 127.0.0.1 "$@"
}

mariadb_cmd <<EOF
CREATE USER IF NOT EXISTS '$NEW_USER'@'%' IDENTIFIED BY '$USER_PASS';
GRANT '$TARGET_ROLE' TO '$NEW_USER'@'%';
SET DEFAULT ROLE '$TARGET_ROLE' FOR '$NEW_USER'@'%';
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
  echo "User '$NEW_USER' created and assigned to '$TARGET_ROLE'."
  echo "MAKE SURE TO SAVE THE PASSWORD: $USER_PASS"
else
  echo "Error creating user. Check if the role exists and if you have proper MariaDB privileges."
fi
echo "------------------------------------------"
