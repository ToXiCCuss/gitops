#!/usr/bin/env bash
# Ensures a MongoDB database and the logins that were created in it do not exist. dropDatabase() keeps
# those logins, so they are dropped first. The system databases admin, local and config are refused.
#
# Idempotent: a missing database without logins is reported as unchanged. The data is deleted for good;
# use --dry-run first. The password of every login is deleted from Vault (databases/mongodb/<database_name>/<username>)
# before the logins are dropped, so a refused delete stops the script while the logins still exist. It needs the
# current policy of scripts/vault/configure-vault-databases.ps1.
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

# existing_state: first line "true" or "false" (the database exists), then one line per login
existing_state() {
  mongo_script <<JS
const exists = db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.some(d => d.name === "$DB_NAME");
print(exists);
db.getSiblingDB("$DB_NAME").runCommand({ usersInfo: 1 }).users.forEach(u => print(u.user));
JS
}

# The scripts only create logins that match NAME_PATTERN, so only those can have a Vault entry
ensure_vault_entries_absent() {
  local user
  for user in "$@"; do
    if [[ $user =~ $NAME_PATTERN ]]; then
      ensure_vault_entry_absent "mongodb/$DB_NAME/$user"
    fi
  done
}

ensure_database_and_users_absent() {
  local state exists user_count
  local -a users
  state=$(existing_state)
  exists=$(head -n 1 <<<"$state")
  mapfile -t users < <(tail -n +2 <<<"$state")
  user_count=${#users[@]}
  if [[ $exists == false && $user_count == 0 ]]; then
    log "unchanged: database $DB_NAME and its logins do not exist"
  elif [[ $DRY_RUN == true ]]; then
    ensure_vault_entries_absent "${users[@]}"
    log "[dry-run] dropped: $user_count logins and database $DB_NAME (exists: $exists) (not executed)"
  else
    ensure_vault_entries_absent "${users[@]}"
    mongo_script <<JS
const target = db.getSiblingDB("$DB_NAME");
target.dropAllUsers();
target.dropDatabase();
JS
    log "dropped: $user_count logins and database $DB_NAME"
  fi
}

main() {
  parse_arguments "$@"
  require_commands mongosh jq
  require_vault_access

  ensure_database_and_users_absent
}

main "$@"
