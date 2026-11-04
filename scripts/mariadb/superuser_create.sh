#!/usr/bin/env bash
# Ensures a personal MariaDB login with full rights: ALL PRIVILEGES on all databases WITH GRANT OPTION.
#
# Meant for a person who administers the server by hand. Application logins never get this (user_create.sh and
# person_grant.sh give rights on single databases).
#
# The login is only allowed from localhost (socket, or TCP from the host itself, e.g. through an SSH tunnel).
# The firewall lets only the Docker networks reach port 3306, so a host '%' would only add Docker containers.
#
# Nothing is written to Vault. The password is typed in at the prompt (asked twice, not echoed) and handed to
# MariaDB on stdin, so it never shows up in the process list, a file or the log. Keep it in your password manager.
#
# Idempotent: an existing user keeps its password and only gets the privileges it is missing. The prompt appears
# for a new user and for "reset".
#
# Usage: superuser_create.sh [--dry-run] <username> [reset]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=80
readonly MIN_PASSWORD_LENGTH=12
readonly USER_HOST="localhost"
readonly FULL_GRANT_PATTERN='^GRANT ALL PRIVILEGES ON \*\.\* TO .* WITH GRANT OPTION'

RESET=false
USER_NAME=""

usage() {
  log "Usage: $0 [--dry-run] <username> [reset]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2)) || usage

  USER_NAME=${POSITIONAL[0]}
  if ((${#POSITIONAL[@]} == 2)); then
    [[ ${POSITIONAL[1]} == reset ]] || usage
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

has_full_privileges() {
  mariadb_admin -e "SHOW GRANTS FOR '$USER_NAME'@'$USER_HOST'" | grep -qE "$FULL_GRANT_PATTERN"
}

# The password goes into a SQL string literal, so the two characters that end or escape it are not allowed
validate_password() {
  local password=$1
  ((${#password} >= MIN_PASSWORD_LENGTH)) || die "the password needs at least $MIN_PASSWORD_LENGTH characters"
  [[ $password != *\'* && $password != *\\* ]] || die "the password must not contain ' or \\"
}

# Prints the password to stdout (captured by the caller), prompts and errors go to stderr
read_password() {
  local first second
  [[ -t 0 ]] || die "a terminal is needed to ask for the password of $USER_NAME"
  read -rsp "Password for $USER_NAME: " first
  log ""
  read -rsp "Repeat password: " second
  log ""
  [[ $first == "$second" ]] || die "the two passwords differ"
  validate_password "$first"
  printf '%s' "$first"
}

# apply_password <CREATE|ALTER> <outcome>: asks for the password first, so a mistyped one changes nothing
apply_password() {
  local statement=$1 outcome=$2 password
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: user $USER_NAME@$USER_HOST, the password would be asked (not executed)"
  else
    password=$(read_password)
    mariadb_admin <<<"$statement USER '$USER_NAME'@'$USER_HOST' IDENTIFIED BY '$password';"
    log "$outcome: user $USER_NAME@$USER_HOST"
  fi
}

ensure_user() {
  if ! user_exists; then
    apply_password CREATE created
  elif [[ $RESET == true ]]; then
    apply_password ALTER updated
  else
    log "unchanged: user $USER_NAME@$USER_HOST (password kept, 'reset' sets a new one)"
  fi
}

ensure_full_privileges() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] ensured: ALL PRIVILEGES on *.* WITH GRANT OPTION for $USER_NAME@$USER_HOST (not executed)"
  elif user_exists && has_full_privileges; then
    log "unchanged: $USER_NAME@$USER_HOST has ALL PRIVILEGES on *.* WITH GRANT OPTION"
  else
    mariadb_admin <<<"GRANT ALL PRIVILEGES ON *.* TO '$USER_NAME'@'$USER_HOST' WITH GRANT OPTION;"
    log "updated: $USER_NAME@$USER_HOST now has ALL PRIVILEGES on *.* WITH GRANT OPTION"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb

  ensure_user
  ensure_full_privileges
}

main "$@"
