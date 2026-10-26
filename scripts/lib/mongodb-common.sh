#!/usr/bin/env bash
# Sourced by the MongoDB scripts (scripts/mongodb), after database-common.sh: runs JavaScript with mongosh.
#
# MongoDB has no peer authentication, so the scripts log in as the admin of /etc/mongodb-admin.cred
# (ADMIN_USER and ADMIN_PASS, root only, mode 600). Without the file they run without credentials, which only
# works through the localhost exception before the first user exists. The login is a statement at the start of
# the script that goes through stdin, so the admin password is never an argument (process list).

readonly MONGO_ADMIN_CREDENTIAL_FILE="/etc/mongodb-admin.cred"
readonly MONGO_SYSTEM_DATABASES=(admin local config)

# mongo_login_statement: the JavaScript statement that logs in as the admin, nothing if there is no credential file
mongo_login_statement() {
  local ADMIN_USER="" ADMIN_PASS=""
  if [[ -f $MONGO_ADMIN_CREDENTIAL_FILE ]]; then
    # shellcheck source=/dev/null
    source "$MONGO_ADMIN_CREDENTIAL_FILE"
    if [[ -n $ADMIN_USER && -n $ADMIN_PASS ]]; then
      jq -nr --arg user "$ADMIN_USER" --arg pass "$ADMIN_PASS" \
        '"db.getSiblingDB(\"admin\").auth(" + ($user | @json) + ", " + ($pass | @json) + ");"'
    fi
  fi
}

# mongo_script: runs the JavaScript from stdin; a failing statement makes mongosh exit with an error
mongo_script() {
  {
    mongo_login_statement
    cat
  } | mongosh --quiet --file /dev/stdin
}

# reject_system_database <name>
reject_system_database() {
  local system_database
  for system_database in "${MONGO_SYSTEM_DATABASES[@]}"; do
    [[ $1 != "$system_database" ]] || die "$1 is a system database"
  done
}
