#!/bin/bash

# Creates the login role Databasus uses for the logical backups, or only repeats the grants if it exists.
#
# pg_read_all_data is a predefined role of the whole cluster: SELECT on all tables, views and
# sequences in ALL databases and schemas (also the ones created later), nothing else. One role
# is enough for the complete DBMS. Do not add it to the application users of user_create.sh,
# they would be able to read every database.
#
# pg_read_all_data does not include the right to connect. db_create.sh revokes CONNECT from PUBLIC,
# so the role gets CONNECT on every existing database here (db_create.sh does it for new ones).
# Run the script again after databases were created in another way.
#
# Usage: backup_user_create.sh [username] [reset]     (default username: databasus)
#        An existing role keeps its password, "reset" sets a new one.

USER_NAME="${1:-databasus}"
RESET="$2"

psql_cmd() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"
}

echo "------------------------------------------"
echo "Backup User: $USER_NAME"

EXISTS=$(sudo -u postgres psql -At -c "SELECT 1 FROM pg_roles WHERE rolname = '$USER_NAME'")

if [ -z "$EXISTS" ] || [ "$RESET" = "reset" ]; then
  USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)
  if [ -z "$EXISTS" ]; then
    psql_cmd -c "CREATE ROLE \"$USER_NAME\" LOGIN PASSWORD '$USER_PASS';" || { echo "Error creating the backup user."; exit 1; }
  else
    psql_cmd -c "ALTER ROLE \"$USER_NAME\" LOGIN PASSWORD '$USER_PASS';" || { echo "Error resetting the password."; exit 1; }
  fi
  echo "Password:    $USER_PASS"
else
  echo "Role exists, password unchanged (use 'reset' to set a new one)."
fi

psql_cmd <<EOF
GRANT pg_read_all_data TO "$USER_NAME";

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', datname, '$USER_NAME')
FROM pg_database
WHERE datallowconn AND NOT datistemplate
\gexec
EOF

if [ $? -eq 0 ]; then
  echo "User '$USER_NAME' can connect to all databases and read them (pg_read_all_data)."
  [ -n "$USER_PASS" ] && echo "MAKE SURE TO SAVE THE PASSWORD: $USER_PASS"
else
  echo "Error granting the privileges."
  exit 1
fi
echo "------------------------------------------"
