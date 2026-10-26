#!/usr/bin/env bash
# Ensures the MariaDB login (host '%') does not exist.
#
# Idempotent: a missing login is reported as unchanged. Open connections of the login stay until they end.
# The password in Vault (databases/mariadb/<login>) is deleted first, whether the login still exists or not, so a
# repeated run also cleans up an old leftover. It needs the current policy of scripts/vault/configure-vault-databases.ps1.
#
# Usage: user_delete.sh [--dry-run] <login>
#        user_delete.sh [--dry-run] <database_name> <username>     (login = <database_name>_<username>)
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=80
readonly USER_HOST="%"
readonly PROTECTED_LOGINS=(root mysql)

LOGIN_NAME=""

usage() {
  log "Usage: $0 [--dry-run] <login> | <database_name> <username>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local protected
  parse_options "$@"
  case ${#POSITIONAL[@]} in
  1) LOGIN_NAME=${POSITIONAL[0]} ;;
  2) LOGIN_NAME="${POSITIONAL[0]}_${POSITIONAL[1]}" ;;
  *) usage ;;
  esac
  validate_name "login name" "$LOGIN_NAME" "$MAX_NAME_LENGTH"
  for protected in "${PROTECTED_LOGINS[@]}"; do
    [[ $LOGIN_NAME != "$protected" ]] || die "$LOGIN_NAME is a system login and cannot be deleted"
  done
}

# The name is validated against NAME_PATTERN, so it can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

ensure_login_absent() {
  if [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$LOGIN_NAME' AND Host = '$USER_HOST' AND is_role = 'N'")" ]]; then
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] dropped: login $LOGIN_NAME (not executed)"
    else
      mariadb_admin <<<"DROP USER '$LOGIN_NAME'@'$USER_HOST';"
      log "dropped: login $LOGIN_NAME"
    fi
  else
    log "unchanged: login $LOGIN_NAME@$USER_HOST does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb
  require_vault_access

  ensure_vault_entry_absent "mariadb/$LOGIN_NAME"
  ensure_login_absent
}

main "$@"
