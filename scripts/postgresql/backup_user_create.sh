#!/bin/bash

# Creates (or resets the password of) the login role Databasus uses for the logical backups.
#
# pg_read_all_data is a predefined role of the whole cluster: SELECT on all tables, views and
# sequences in ALL databases and schemas (also the ones created later), nothing else. One role
# is enough for the complete DBMS. Do not add it to the application users of user_create.sh,
# they would be able to read every database.
#
# Usage: backup_user_create.sh [username]     (default: databasus)

USER_NAME="${1:-databasus}"
USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

echo "------------------------------------------"
echo "Backup User: $USER_NAME"
echo "Password:    $USER_PASS"

sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$USER_NAME') THEN
    CREATE ROLE "$USER_NAME" LOGIN PASSWORD '$USER_PASS';
  ELSE
    ALTER ROLE "$USER_NAME" LOGIN PASSWORD '$USER_PASS';
  END IF;
END
\$\$;

GRANT pg_read_all_data TO "$USER_NAME";
EOF

if [ $? -eq 0 ]; then
  echo "User '$USER_NAME' can read all databases (pg_read_all_data)."
  echo "MAKE SURE TO SAVE THE PASSWORD: $USER_PASS"
else
  echo "Error creating the backup user."
  exit 1
fi
echo "------------------------------------------"
