#!/usr/bin/env bash
# Ensures the MariaDB database <database_name> and everything db_create.sh made for it does not exist: the
# database, the logins that have one of its three roles and the roles (<db>_role_ro, _rw, _owner).
#
# Idempotent: parts that are already gone are reported as unchanged, so an aborted run can be repeated.
# The data is deleted for good; use --dry-run first. The password of every login is deleted from Vault
# (databases/mariadb/<login>) before the login is dropped, so a refused delete stops the script while the
# login still exists. It needs the current policy of scripts/vault/configure-vault-databases.ps1.
#
# A login belongs to the database if it has one of its roles (not by its name, so the logins of a
# database called <db>_dev are not touched).
#
# Usage: db_delete.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=52
readonly PROTECTED_DATABASES=(mysql sys information_schema performance_schema)

DB_NAME=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local protected
  parse_options "$@"
  ((${#POSITIONAL[@]} == 1)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  for protected in "${PROTECTED_DATABASES[@]}"; do
    [[ $DB_NAME != "$protected" ]] || die "$DB_NAME is a system database and cannot be deleted"
  done
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"
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

ensure_database_absent() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$DB_NAME'")" ]]; then
    apply_sql dropped "database $DB_NAME" <<<"DROP DATABASE \`$DB_NAME\`;"
  else
    log "unchanged: database $DB_NAME does not exist"
  fi
}

# CREATE ROLE gives the creating account (root) the role WITH ADMIN OPTION, which is also a row in
# roles_mapping: only plain assignments (Admin_option = 'N') make a login belong to the database, and the system
# logins are never dropped. QUOTE() makes the statement safe for any user and host name found in the system table.
# One line per login: the user name, a tab and the DROP USER statement (--batch separates the columns with tabs).
ensure_logins_absent() {
  local statements login statement
  statements=$(mariadb_admin -e "
    SELECT DISTINCT u.User, CONCAT('DROP USER ', QUOTE(u.User), '@', QUOTE(u.Host), ';')
    FROM mysql.roles_mapping m
    JOIN mysql.user u ON u.User = m.User AND u.Host = m.Host
    WHERE m.Role IN ('$ROLE_RO', '$ROLE_RW', '$ROLE_OWNER') AND m.Admin_option = 'N'
      AND u.is_role = 'N' AND u.User NOT IN ('root', 'mysql', 'mariadb.sys')
    ORDER BY 1, 2")
  if [[ -z $statements ]]; then
    log "unchanged: no logins of $DB_NAME"
  else
    while IFS=$'\t' read -r login statement; do
      ensure_vault_entry_absent "mariadb/$login"
      apply_sql dropped "${statement%;}" <<<"$statement"
    done <<<"$statements"
  fi
}

ensure_role_absent() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$1' AND is_role = 'Y'")" ]]; then
    apply_sql dropped "role $1" <<<"DROP ROLE '$1';"
  else
    log "unchanged: role $1 does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb
  require_vault_access

  ensure_database_absent
  ensure_logins_absent
  ensure_role_absent "$ROLE_RO"
  ensure_role_absent "$ROLE_RW"
  ensure_role_absent "$ROLE_OWNER"
  log "Done: $DB_NAME"
}

main "$@"
