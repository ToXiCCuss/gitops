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

DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Creating MariaDB Database (Schema): $DB_NAME"
echo "Creating User:                     $DB_USER"
echo "Roles:                             $ROLE_RO, $ROLE_RW, $ROLE_OWNER"
echo "Password:                          $DB_PASS"

mariadb_cmd() {
  sudo mariadb "$@"
}

# In MariaDB, Database and Schema are synonymous.
mariadb_cmd <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;

-- Create roles
CREATE ROLE IF NOT EXISTS '$ROLE_RO';
CREATE ROLE IF NOT EXISTS '$ROLE_RW';
CREATE ROLE IF NOT EXISTS '$ROLE_OWNER';

-- Grant permissions to roles
-- Read-Only
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO '$ROLE_RO';

-- Read-Write
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB_NAME\`.* TO '$ROLE_RW';

-- Owner
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$ROLE_OWNER';

-- Create owner user and assign owner role
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT '$ROLE_OWNER' TO '$DB_USER'@'%';
SET DEFAULT ROLE '$ROLE_OWNER' FOR '$DB_USER'@'%';

FLUSH PRIVILEGES;
EOF


echo "Setup for $DB_NAME completed successfully."
echo "------------------------------------------"
