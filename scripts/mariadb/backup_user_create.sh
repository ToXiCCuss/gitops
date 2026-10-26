#!/usr/bin/env bash
# Ensures the login Databasus uses for the logical backups.
#
# The user may read everything a dump needs and write nothing: SELECT (also the routines),
# SHOW VIEW, TRIGGER, EVENT and LOCK TABLES on all databases, also on the ones created later.
# Do not give it to the application users of user_create.sh, they would be able to read
# every database.
#
# The login is allowed from any host ('%'). Who can reach the database port is decided by the
# firewall (the rule for port 3306 only lets the Docker networks in, like the one for PostgreSQL),
# so do not open that port further.
#
# Idempotent: an existing user keeps its password and only gets the grants it is missing. The password of a
# new user goes to Vault (databases/mariadb/<username>) and is never printed; "reset" sets a new one.
# Vault is written first, so an unreachable Vault stops the script before anything is changed.
#
# Usage: backup_user_create.sh [--dry-run] [username] [reset]     (default username: databasus)
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly DEFAULT_USER_NAME="databasus"
# the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=80
readonly USER_HOST="%"
readonly BACKUP_PRIVILEGES="SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES"

DRY_RUN=false
RESET=false
USER_NAME="$DEFAULT_USER_NAME"

usage() {
  log "Usage: $0 [--dry-run] [username] [reset]"
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
  ((${#positional[@]} <= 2)) || usage

  USER_NAME=${positional[0]:-$DEFAULT_USER_NAME}
  if ((${#positional[@]} == 2)); then
    [[ ${positional[1]} == reset ]] || usage
    RESET=true
  fi
  validate_name "username" "$USER_NAME" "$MAX_NAME_LENGTH"
}

# The name is validated against NAME_PATTERN, so it can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

user_exists() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$USER_NAME' AND Host = '$USER_HOST'")" ]]
}

# apply_new_password <CREATE|ALTER> <outcome>: Vault first, then the user gets the same password
apply_new_password() {
  local statement=$1 outcome=$2 password
  password=$(generate_password)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: backup user $USER_NAME (not executed)"
  else
    vault_store_password mariadb "$USER_NAME" "$password"
    mariadb_admin <<<"$statement USER '$USER_NAME'@'$USER_HOST' IDENTIFIED BY '$password';"
    log "$outcome: backup user $USER_NAME"
  fi
}

ensure_backup_user() {
  if ! user_exists; then
    apply_new_password CREATE created
  elif [[ $RESET == true ]]; then
    apply_new_password ALTER updated
  else
    log "unchanged: backup user $USER_NAME (password kept, 'reset' sets a new one)"
  fi
}

# Grants can be repeated without effect, so they are applied on every run
apply_backup_privileges() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] applied: $BACKUP_PRIVILEGES on *.* for $USER_NAME (not executed)"
  else
    mariadb_admin <<<"GRANT $BACKUP_PRIVILEGES ON *.* TO '$USER_NAME'@'$USER_HOST';"
    log "applied: $BACKUP_PRIVILEGES on *.* for $USER_NAME"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb openssl
  require_vault_access

  ensure_backup_user
  apply_backup_privileges
  log "In Databasus: add the database with this user, host = this server, port 3306, and use 'Test connection'."
}

main "$@"
