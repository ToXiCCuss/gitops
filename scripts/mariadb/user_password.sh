#!/usr/bin/env bash
# Sets a new random password for a MariaDB login (host '%') and stores it in Vault
# (databases/mariadb/<login>); the password is never printed.
#
# This is a rotation, so every run sets a new password (the older ones stay as versions in Vault). Vault is
# written first. If the ALTER USER fails afterwards, Vault holds a password the login does not have yet:
# run the script again, it sets both to the same new password. Logins that were created before the
# scripts used Vault are put into Vault by their first run.
#
# Usage: user_password.sh [--dry-run] <login>
#        user_password.sh [--dry-run] <database_name> <username>     (login = <database_name>_<username>)
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=80
readonly USER_HOST="%"

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

# The name is validated against NAME_PATTERN, so it can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

require_login() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$LOGIN_NAME' AND Host = '$USER_HOST' AND is_role = 'N'")" ]] ||
    die "login $LOGIN_NAME@$USER_HOST does not exist"
}

rotate_password() {
  local password
  password=$(generate_password)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: password of $LOGIN_NAME (not executed)"
  else
    vault_store_password "mariadb/$LOGIN_NAME" "$LOGIN_NAME" "$password"
    mariadb_admin <<<"ALTER USER '$LOGIN_NAME'@'$USER_HOST' IDENTIFIED BY '$password';"
    log "updated: password of $LOGIN_NAME"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb openssl
  require_vault_access
  require_login

  rotate_password
}

main "$@"
