#!/usr/bin/env bash
# Ensures a MongoDB database and the logins that were created in it do not exist. dropDatabase() keeps
# those logins, so they are dropped first. The system databases admin, local and config are refused.
#
# Idempotent: a missing database without logins is reported as unchanged. The data is deleted for good;
# use --dry-run first. The passwords in Vault stay, because the host may only write there: delete them as
# admin with
#   vault kv metadata delete databases/mongodb/<database_name>/<username>
#
# Usage: cleanup_db_user.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"
# shellcheck source=../lib/mongodb-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/mongodb-common.sh"

readonly MAX_NAME_LENGTH=63

DB_NAME=""

usage() {
  log "Usage: $0 [--dry-run] <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 1)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  reject_system_database "$DB_NAME"
}

# existing_state: "<database exists: true|false> <number of logins>"
existing_state() {
  mongo_script <<JS
const exists = db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.some(d => d.name === "$DB_NAME");
const users = db.getSiblingDB("$DB_NAME").runCommand({ usersInfo: 1 }).users.length;
print(exists + " " + users);
JS
}

ensure_database_and_users_absent() {
  local state exists users
  state=$(existing_state)
  read -r exists users <<<"$state"
  if [[ $exists == false && $users == 0 ]]; then
    log "unchanged: database $DB_NAME and its logins do not exist"
  elif [[ $DRY_RUN == true ]]; then
    log "[dry-run] dropped: $users logins and database $DB_NAME (exists: $exists) (not executed)"
  else
    mongo_script <<JS
const target = db.getSiblingDB("$DB_NAME");
target.dropAllUsers();
target.dropDatabase();
JS
    log "dropped: $users logins and database $DB_NAME (their Vault entries stay)"
  fi
}

main() {
  parse_arguments "$@"
  require_commands mongosh jq

  ensure_database_and_users_absent
}

main "$@"
