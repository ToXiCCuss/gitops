#!/bin/bash

# Creates the login Databasus uses for the logical backups, or only repeats the grants if it exists.
#
# The user may read everything a dump needs and write nothing: SELECT (also the routines),
# SHOW VIEW, TRIGGER, EVENT and LOCK TABLES on all databases, also on the ones created later.
# Do not give it to the application users of user_create.sh, they would be able to read
# every database.
#
# The login is allowed from any host ('%'). Who can reach the database port is decided by the
# firewall (the rule for port 3306 only lets the Docker networks in, like the one for PostgreSQL),
# so do not open that port further.
#
# Usage: backup_user_create.sh [username] [reset]     (default username: databasus)
#        An existing user keeps its password, "reset" sets a new one.

USER_HOST="%"

USER_NAME="${1:-databasus}"
RESET="$2"

if [[ ! "$USER_NAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "Error: the user name may only contain letters, digits and underscores."
  exit 1
fi

mariadb_cmd() {
  sudo mariadb "$@"
}

echo "------------------------------------------"
echo "Backup User: $USER_NAME@$USER_HOST"

USER_EXISTS=$(mariadb_cmd -N -B -e "SELECT 1 FROM mysql.user WHERE User = '$USER_NAME' AND Host = '$USER_HOST'")

if [ -z "$USER_EXISTS" ] || [ "$RESET" = "reset" ]; then
  USER_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 30)

  if [ -z "$USER_EXISTS" ]; then
    mariadb_cmd -e "CREATE USER '$USER_NAME'@'$USER_HOST' IDENTIFIED BY '$USER_PASS';" || { echo "Error creating the backup user."; exit 1; }
  else
    mariadb_cmd -e "ALTER USER '$USER_NAME'@'$USER_HOST' IDENTIFIED BY '$USER_PASS';" || { echo "Error resetting the password."; exit 1; }
  fi
  echo "Password:    $USER_PASS"
else
  echo "User exists, password unchanged (use 'reset' to set a new one)."
fi

mariadb_cmd -e "GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON *.* TO '$USER_NAME'@'$USER_HOST'; FLUSH PRIVILEGES;" || { echo "Error granting the privileges."; exit 1; }

echo "Privileges:  SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES on *.*"
echo "In Databasus: add the database with this user, host = this server, port 3306, and use 'Test connection'."
echo "------------------------------------------"
