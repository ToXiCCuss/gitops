#!/usr/bin/env bash
# Ensures a MongoDB login with the given roles on a database.
#
# Idempotent: an existing login keeps its password and only gets its roles set to the given ones. The password
# of a new login goes to Vault (databases/mongodb/<database_name>/<username>) and is never printed.
#
# Roles: ro (read), rw (readWrite), owner (dbOwner) or any MongoDB role of the database such as dbAdmin or
# userAdmin. Without roles it asks on a terminal and takes readWrite when there is none.
#
# Usage: create_user.sh [--dry-run] <database_name> <username> [role ...]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"
# shellcheck source=../lib/mongodb-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/mongodb-common.sh"

readonly MAX_DATABASE_NAME_LENGTH=52
readonly MAX_USER_NAME_LENGTH=64
readonly ROLE_PATTERN='^[A-Za-z]+$'
readonly DEFAULT_ROLE="readWrite"

DB_NAME=""
DB_USER=""
ROLES=()

usage() {
  log "Usage: $0 [--dry-run] <database_name> <username> [role ...]"
  log "Roles: ro (read), rw (readWrite), owner (dbOwner), dbAdmin, userAdmin or any other role of the database"
  exit "$EXIT_USAGE"
}

# expand_role <name>: the MongoDB role for the short names
expand_role() {
  case $1 in
  ro) echo "read" ;;
  rw) echo "readWrite" ;;
  owner) echo "dbOwner" ;;
  *) echo "$1" ;;
  esac
}

# choose_role_interactively: asks for one role on a terminal
choose_role_interactively() {
  local custom_role choice
  log "No roles given. Choose a role for '$DB_USER' on database '$DB_NAME':"
  select choice in "readWrite (rw)" "read (ro)" "dbOwner (owner)" "dbAdmin" "userAdmin" "Custom..."; do
    case $choice in
    "readWrite (rw)") echo "readWrite" ;;
    "read (ro)") echo "read" ;;
    "dbOwner (owner)") echo "dbOwner" ;;
    "Custom...")
      read -r -p "Enter custom role: " custom_role
      echo "$custom_role"
      ;;
    "") continue ;;
    *) echo "$choice" ;;
    esac
    break
  done
}

parse_arguments() {
  local role
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  DB_USER=${POSITIONAL[1]}
  validate_name "database name" "$DB_NAME" "$MAX_DATABASE_NAME_LENGTH"
  validate_name "username" "$DB_USER" "$MAX_USER_NAME_LENGTH"
  reject_system_database "$DB_NAME"

  for role in "${POSITIONAL[@]:2}"; do
    ROLES+=("$(expand_role "$role")")
  done
  if ((${#ROLES[@]} == 0)) && [[ -t 0 ]]; then
    ROLES+=("$(choose_role_interactively)")
  fi
  ((${#ROLES[@]} > 0)) || ROLES=("$DEFAULT_ROLE")
  for role in "${ROLES[@]}"; do
    [[ $role =~ $ROLE_PATTERN ]] || die "invalid role '$role'"
  done
}

# roles_json: [{"role":"...","db":"..."}, ...] for createUser and updateUser
roles_json() {
  printf '%s\n' "${ROLES[@]}" | jq -R --arg db "$DB_NAME" '{role: ., db: $db}' | jq -sc .
}

# user_state: absent, same (exactly these roles) or different
user_state() {
  mongo_script <<JS
const wanted = $(roles_json).map(r => r.role + "@" + r.db).sort().join();
const user = db.getSiblingDB("$DB_NAME").getUser("$DB_USER");
print(user === null ? "absent" : (user.roles.map(r => r.role + "@" + r.db).sort().join() === wanted ? "same" : "different"));
JS
}

# The password reaches mongosh through stdin; Vault is written first, so an unreachable Vault changes nothing
ensure_user() {
  local state password
  state=$(user_state)
  case $state in
  absent)
    password=$(generate_password)
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] created: user $DB_USER on $DB_NAME with ${ROLES[*]} (not executed)"
    else
      vault_store_password "mongodb/$DB_NAME/$DB_USER" "$DB_USER" "$password"
      mongo_script <<JS
db.getSiblingDB("$DB_NAME").createUser({ user: "$DB_USER", pwd: "$password", roles: $(roles_json) });
JS
      log "created: user $DB_USER on $DB_NAME with ${ROLES[*]}"
    fi
    ;;
  same) log "unchanged: user $DB_USER on $DB_NAME has ${ROLES[*]} (password kept, reset_password.sh sets a new one)" ;;
  *)
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] updated: roles of $DB_USER to ${ROLES[*]} (not executed)"
    else
      mongo_script <<JS
db.getSiblingDB("$DB_NAME").updateUser("$DB_USER", { roles: $(roles_json) });
JS
      log "updated: roles of $DB_USER on $DB_NAME to ${ROLES[*]}"
    fi
    ;;
  esac
}

main() {
  parse_arguments "$@"
  require_commands mongosh jq curl openssl
  require_vault_access

  ensure_user
  log "Done: $DB_USER"
}

main "$@"
