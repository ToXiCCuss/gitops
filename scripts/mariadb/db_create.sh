#!/usr/bin/env bash
# Ensures a MariaDB database (schema) with its three roles (<db>_role_ro, _rw, _owner) and the login <db>_owner.
#
# Idempotent: a missing part is created, an existing part is left as it is, so a run that was aborted
# can simply be started again. The password of a newly created <db>_owner goes to Vault
# (databases/mariadb/<db>_owner) and is never printed; an existing user keeps its password
# (user_password.sh sets a new one).
#
# Usage: db_create.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=52
readonly USER_HOST="%"

DRY_RUN=false
DB_NAME=""
DB_USER=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local positional=()
  while (($# > 0)); do
    case $1 in
    --dry-run) DRY_RUN=true ;;
    -*) usage ;;
    *) positional+=("$1") ;;
    esac
    shift
  done
  ((${#positional[@]} == 1)) || usage

  DB_NAME=${positional[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  DB_USER="${DB_NAME}_owner"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"
}

# The names are validated against NAME_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

# query_exists <sql>: true if the query returns a row
query_exists() {
  [[ -n "$(mariadb_admin -e "$1")" ]]
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

# In MariaDB, database and schema are synonymous.
ensure_database() {
  if query_exists "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME'"; then
    log "unchanged: database $DB_NAME"
  else
    apply_sql created "database $DB_NAME" <<<"CREATE DATABASE \`$DB_NAME\`;"
  fi
}

ensure_role() {
  if query_exists "SELECT 1 FROM mysql.user WHERE User = '$1' AND is_role = 'Y'"; then
    log "unchanged: role $1"
  else
    apply_sql created "role $1" <<<"CREATE ROLE '$1';"
  fi
}

# Grants can be repeated without effect, so they are applied on every run
apply_role_privileges() {
  apply_sql applied "privileges of the roles on $DB_NAME" <<SQL
GRANT SELECT, LOCK TABLES, SHOW VIEW, TRIGGER ON \`$DB_NAME\`.* TO '$ROLE_RO';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB_NAME\`.* TO '$ROLE_RW';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$ROLE_OWNER';
SQL
}

# The role assignment below can be repeated, so a failed run is finished by running the script again
ensure_owner_user() {
  if query_exists "SELECT 1 FROM mysql.user WHERE User = '$DB_USER' AND Host = '$USER_HOST'"; then
    log "unchanged: user $DB_USER (password kept, user_password.sh sets a new one)"
  else
    local password
    password=$(generate_password)
    # Into Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one
    [[ $DRY_RUN == true ]] || vault_store_password mariadb "$DB_USER" "$password"
    apply_sql created "user $DB_USER" <<<"CREATE USER '$DB_USER'@'$USER_HOST' IDENTIFIED BY '$password';"
  fi

  apply_sql applied "role $ROLE_OWNER of $DB_USER" <<SQL
GRANT '$ROLE_OWNER' TO '$DB_USER'@'$USER_HOST';
SET DEFAULT ROLE '$ROLE_OWNER' FOR '$DB_USER'@'$USER_HOST';
SQL
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb openssl
  require_vault_access

  ensure_database
  ensure_role "$ROLE_RO"
  ensure_role "$ROLE_RW"
  ensure_role "$ROLE_OWNER"
  apply_role_privileges
  ensure_owner_user
  log "Done: $DB_NAME"
}

main "$@"
