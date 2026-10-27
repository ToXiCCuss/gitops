#!/usr/bin/env bash
# Ensures the personal login <username> and its read-only or read-write access to one database.
#
# One login serves many databases: every run sets the access to a single database, so <username> can be
# 'ro' in one database and 'rw' in another. MariaDB enables only one default role per connection, so the login
# gets a role of its own (<username>_role_person) as default role and the access is the membership of that role
# in <db>_role_ro or <db>_role_rw (created by db_create.sh). A person is never made owner.
#
# Idempotent: an existing login keeps its password and only gets the role membership it is missing. The password
# of a newly created login goes to Vault (databases/mariadb/<username>) and is never printed (user_password.sh
# sets a new one). The script only touches logins that have such a person role, so it cannot change an
# application login like shop_owner or root.
#
# Usage: person_grant.sh [--dry-run] <username> <database_name> <role_type: ro|rw>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<username>_role_person" and "<db>_role_owner" have to fit into the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=52
readonly USER_HOST="%"

LOGIN=""
PERSON_ROLE=""
DB_NAME=""
TARGET_ROLE=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <username> <database_name> <role_type: ro|rw>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 3)) || usage

  LOGIN=${POSITIONAL[0]}
  DB_NAME=${POSITIONAL[1]}
  validate_name "username" "$LOGIN" "$MAX_NAME_LENGTH"
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  PERSON_ROLE="${LOGIN}_role_person"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"

  case ${POSITIONAL[2]} in
  ro) TARGET_ROLE=$ROLE_RO ;;
  rw) TARGET_ROLE=$ROLE_RW ;;
  *) die "invalid role type '${POSITIONAL[2]}', use 'ro' or 'rw' (owner access is the login ${DB_NAME}_owner of db_create.sh)" ;;
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

login_exists() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$LOGIN' AND Host = '$USER_HOST' AND is_role = 'N'")" ]]
}

person_role_exists() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$PERSON_ROLE' AND is_role = 'Y'")" ]]
}

# Checked before anything is created, so an application login is never taken over
require_person_login_or_absent() {
  if login_exists; then
    person_role_exists ||
      die "$LOGIN exists but was not created by person_grant.sh (no role $PERSON_ROLE), so it is left alone"
  fi
}

# The role comes before the login: a run that stops in between leaves a role without a login, which the rerun
# completes, instead of a login without its marker that would be refused
ensure_person_role() {
  if person_role_exists; then
    log "unchanged: role $PERSON_ROLE"
  else
    apply_sql created "role $PERSON_ROLE" <<<"CREATE ROLE '$PERSON_ROLE';"
  fi
}

ensure_login() {
  if login_exists; then
    log "unchanged: login $LOGIN (password kept, user_password.sh sets a new one)"
  else
    local password
    password=$(generate_password)
    # Into Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one
    [[ $DRY_RUN == true ]] || vault_store_password "mariadb/$LOGIN" "$LOGIN" "$password"
    apply_sql created "login $LOGIN" <<<"CREATE USER '$LOGIN'@'$USER_HOST' IDENTIFIED BY '$password';"
  fi
}

ensure_person_role_is_default() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user u JOIN mysql.roles_mapping m ON m.User = u.User AND m.Host = u.Host
    WHERE u.User = '$LOGIN' AND u.Host = '$USER_HOST' AND m.Role = '$PERSON_ROLE' AND u.default_role = '$PERSON_ROLE'")" ]]; then
    log "unchanged: $LOGIN has the default role $PERSON_ROLE"
  else
    apply_sql updated "default role of $LOGIN (now: $PERSON_ROLE)" <<SQL
GRANT '$PERSON_ROLE' TO '$LOGIN'@'$USER_HOST';
SET DEFAULT ROLE '$PERSON_ROLE' FOR '$LOGIN'@'$USER_HOST';
SQL
  fi
}

# The person role has at most one of the three roles of the database, so it loses the others
ensure_role_assignment() {
  local current_roles=() current role statements="" outcome=updated
  current=$(mariadb_admin -e "SELECT GROUP_CONCAT(Role ORDER BY Role SEPARATOR ' ') FROM mysql.roles_mapping
    WHERE User = '$PERSON_ROLE' AND Role IN ('$ROLE_RO', '$ROLE_RW', '$ROLE_OWNER')")
  [[ $current != NULL ]] || current=""
  read -ra current_roles <<<"$current"

  if [[ $current == "$TARGET_ROLE" ]]; then
    log "unchanged: $LOGIN has $TARGET_ROLE (through $PERSON_ROLE)"
  else
    [[ -n $current ]] || outcome=created
    for role in "${current_roles[@]}"; do
      [[ $role == "$TARGET_ROLE" ]] || statements+="REVOKE '$role' FROM '$PERSON_ROLE';"$'\n'
    done
    apply_sql "$outcome" "access of $LOGIN to $DB_NAME (was: ${current:-none}, now: $TARGET_ROLE)" <<SQL
${statements}GRANT '$TARGET_ROLE' TO '$PERSON_ROLE';
SQL
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb openssl
  require_vault_access
  require_database_and_role
  require_person_login_or_absent

  ensure_person_role
  ensure_login
  ensure_person_role_is_default
  ensure_role_assignment
  log "Done: $LOGIN on $DB_NAME as ${TARGET_ROLE##*_}"
}

main "$@"
