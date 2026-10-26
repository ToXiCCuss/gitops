#!/usr/bin/env bash
# Ensures a login <database_name>_<username> that has exactly one role of the database
# (<db>_role_ro, _rw or _owner, created by db_create.sh).
#
# Idempotent: an existing user keeps its password and only gets the role it is missing. The password
# of a newly created user goes to Vault (databases/mariadb/<db>_<username>) and is never printed
# (user_password.sh sets a new one).
#
# Usage: user_create.sh [--dry-run] <database_name> <username> <role_type: ro|rw|owner>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<db>_<username>" and "<db>_role_owner" have to fit into the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=52
readonly USER_HOST="%"

DB_NAME=""
FULL_USER=""
TARGET_ROLE=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> <username> <role_type: ro|rw|owner>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 3)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  validate_name "username" "${POSITIONAL[1]}" "$MAX_NAME_LENGTH"
  FULL_USER="${DB_NAME}_${POSITIONAL[1]}"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"

  case ${POSITIONAL[2]} in
  ro) TARGET_ROLE=$ROLE_RO ;;
  rw) TARGET_ROLE=$ROLE_RW ;;
  owner) TARGET_ROLE=$ROLE_OWNER ;;
  *) die "invalid role type '${POSITIONAL[2]}', use 'ro', 'rw' or 'owner'" ;;
  esac
}

# The names are validated against NAME_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

# apply_sql <outcome> <resource>: runs the SQL from stdin, or only reports it with --dry-run
apply_sql() {
  local outcome=$1 resource=$2
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    mariadb_admin
    log "$outcome: $resource"
  fi
}

require_database_and_role() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME'")" ]] ||
    die "database $DB_NAME does not exist (db_create.sh creates it)"
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$TARGET_ROLE' AND is_role = 'Y'")" ]] ||
    die "role $TARGET_ROLE does not exist (db_create.sh creates it)"
}

ensure_user() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$FULL_USER' AND Host = '$USER_HOST'")" ]]; then
    log "unchanged: user $FULL_USER (password kept, user_password.sh sets a new one)"
  else
    local password
    password=$(generate_password)
    # Into Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one
    [[ $DRY_RUN == true ]] || vault_store_password "mariadb/$FULL_USER" "$FULL_USER" "$password"
    apply_sql created "user $FULL_USER" <<<"CREATE USER '$FULL_USER'@'$USER_HOST' IDENTIFIED BY '$password';"
  fi
}

# The user has exactly one of the three roles of the database, so it loses the others
ensure_role_assignment() {
  local current_roles=() current role statements=""
  current=$(mariadb_admin -e "SELECT GROUP_CONCAT(Role ORDER BY Role SEPARATOR ' ') FROM mysql.roles_mapping
    WHERE User = '$FULL_USER' AND Host = '$USER_HOST' AND Role IN ('$ROLE_RO', '$ROLE_RW', '$ROLE_OWNER')")
  [[ $current != NULL ]] || current=""
  read -ra current_roles <<<"$current"

  if [[ $current == "$TARGET_ROLE" ]]; then
    log "unchanged: $FULL_USER has role $TARGET_ROLE"
  else
    for role in "${current_roles[@]}"; do
      [[ $role == "$TARGET_ROLE" ]] || statements+="REVOKE '$role' FROM '$FULL_USER'@'$USER_HOST';"$'\n'
    done
    apply_sql updated "role of $FULL_USER (was: ${current:-none}, now: $TARGET_ROLE)" <<SQL
${statements}GRANT '$TARGET_ROLE' TO '$FULL_USER'@'$USER_HOST';
SET DEFAULT ROLE '$TARGET_ROLE' FOR '$FULL_USER'@'$USER_HOST';
SQL
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb openssl
  require_vault_access
  require_database_and_role

  ensure_user
  ensure_role_assignment
  log "Done: $FULL_USER"
}

main "$@"
