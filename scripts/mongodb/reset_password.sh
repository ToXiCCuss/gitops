#!/usr/bin/env bash
# Sets a new random password for a MongoDB login and stores it in Vault (databases/mongodb/<database_name>/<username>);
# the password is never printed.
#
# This is a rotation, so every run sets a new password (the older ones stay as versions in Vault). Vault is
# written first. If changing the password fails afterwards, Vault holds one the login does not have yet:
# run the script again, it sets both to the same new password. Logins that were created before the scripts
# used Vault are put into Vault by their first run.
#
# Usage: reset_password.sh [--dry-run] <database_name> <username>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"
# shellcheck source=../lib/mongodb-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/mongodb-common.sh"

readonly MAX_DATABASE_NAME_LENGTH=52
readonly MAX_USER_NAME_LENGTH=64

DB_NAME=""
DB_USER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> <username>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  DB_USER=${POSITIONAL[1]}
  validate_name "database name" "$DB_NAME" "$MAX_DATABASE_NAME_LENGTH"
  validate_name "username" "$DB_USER" "$MAX_USER_NAME_LENGTH"
  reject_system_database "$DB_NAME"
}

require_user() {
  [[ $(mongo_script <<<"print(db.getSiblingDB(\"$DB_NAME\").getUser(\"$DB_USER\") === null ? \"absent\" : \"present\")") == present ]] ||
    die "user $DB_USER does not exist in $DB_NAME"
}

rotate_password() {
  local password
  password=$(generate_password)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: password of $DB_USER on $DB_NAME (not executed)"
  else
    vault_store_password "mongodb/$DB_NAME/$DB_USER" "$DB_USER" "$password"
    mongo_script <<<"db.getSiblingDB(\"$DB_NAME\").changeUserPassword(\"$DB_USER\", \"$password\");"
    log "updated: password of $DB_USER on $DB_NAME"
  fi
}

main() {
  parse_arguments "$@"
  require_commands mongosh jq curl openssl
  require_vault_access
  require_user

  rotate_password
}

main "$@"
