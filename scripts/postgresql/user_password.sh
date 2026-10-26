#!/usr/bin/env bash
# Sets a new random password for a PostgreSQL login and stores it in Vault
# (databases/postgresql/<login>); the password is never printed.
#
# This is a rotation, so every run sets a new password (the older ones stay as versions in Vault). Vault is
# written first. If the ALTER ROLE fails afterwards, Vault holds a password the login does not have yet:
# run the script again, it sets both to the same new password. Logins that were created before the
# scripts used Vault are put into Vault by their first run.
#
# Usage: user_password.sh [--dry-run] <login>
#        user_password.sh [--dry-run] <database_name> <username>     (login = <database_name>_<username>)
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly MAX_NAME_LENGTH=63

LOGIN_NAME=""

usage() {
  log "Usage: $0 [--dry-run] <login> | <database_name> <username>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"

  case ${#POSITIONAL[@]} in
  1) LOGIN_NAME=${POSITIONAL[0]} ;;
  2) LOGIN_NAME="${POSITIONAL[0]}_${POSITIONAL[1]}" ;;
  *) usage ;;
  esac
  validate_name "login name" "$LOGIN_NAME" "$MAX_NAME_LENGTH"
}

# The name reaches the SQL as a psql variable (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v login_name="$LOGIN_NAME" "$@"
}

require_login() {
  [[ -n "$(psql_admin --no-align --tuples-only <<<"SELECT 1 FROM pg_roles WHERE rolname = :'login_name' AND rolcanlogin")" ]] ||
    die "login $LOGIN_NAME does not exist"
}

rotate_password() {
  local password
  password=$(generate_password)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: password of $LOGIN_NAME (not executed)"
  else
    vault_store_password "postgresql/$LOGIN_NAME" "$LOGIN_NAME" "$password"
    psql_admin <<SQL
\\set new_password '$password'
ALTER ROLE :"login_name" WITH PASSWORD :'new_password';
SQL
    log "updated: password of $LOGIN_NAME"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql openssl
  require_vault_access
  require_login

  rotate_password
}

main "$@"
