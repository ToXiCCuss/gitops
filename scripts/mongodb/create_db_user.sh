#!/usr/bin/env bash
# Ensures the owner login <database_name>_owner of a MongoDB database with the role dbOwner on it.
# MongoDB creates the database itself with its first data.
#
# Idempotent: an existing login keeps its password and only gets the role if it is missing. The password
# of a new login goes to Vault (databases/mongodb/<database_name>/<database_name>_owner) and is never printed.
#
# Usage: create_db_user.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"
# shellcheck source=../lib/mongodb-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/mongodb-common.sh"

readonly MAX_NAME_LENGTH=52
readonly OWNER_ROLE="dbOwner"

DB_NAME=""
DB_USER=""

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
  DB_USER="${DB_NAME}_owner"
}

# user_state: absent, same (has the role) or different
user_state() {
  mongo_script <<JS
const user = db.getSiblingDB("$DB_NAME").getUser("$DB_USER");
print(user === null ? "absent" : (user.roles.some(r => r.role === "$OWNER_ROLE" && r.db === "$DB_NAME") ? "same" : "different"));
JS
}

# The password reaches mongosh through stdin; Vault is written first, so an unreachable Vault changes nothing
ensure_owner_user() {
  local state password
  state=$(user_state)
  case $state in
  absent)
    password=$(generate_password)
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] created: user $DB_USER on $DB_NAME (not executed)"
    else
      vault_store_password "mongodb/$DB_NAME/$DB_USER" "$DB_USER" "$password"
      mongo_script <<JS
db.getSiblingDB("$DB_NAME").createUser({ user: "$DB_USER", pwd: "$password", roles: [{ role: "$OWNER_ROLE", db: "$DB_NAME" }] });
JS
      log "created: user $DB_USER on $DB_NAME"
    fi
    ;;
  same) log "unchanged: user $DB_USER on $DB_NAME (password kept, reset_password.sh sets a new one)" ;;
  *)
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] updated: roles of $DB_USER (not executed)"
    else
      mongo_script <<JS
db.getSiblingDB("$DB_NAME").updateUser("$DB_USER", { roles: [{ role: "$OWNER_ROLE", db: "$DB_NAME" }] });
JS
      log "updated: roles of $DB_USER on $DB_NAME"
    fi
    ;;
  esac
}

main() {
  parse_arguments "$@"
  require_commands mongosh jq curl openssl
  require_vault_access

  ensure_owner_user
  log "Done: $DB_NAME"
}

main "$@"
