#!/usr/bin/env bash
# Ensures a personal PostgreSQL login with SUPERUSER: full rights on every database and the whole cluster.
#
# Meant for a person who administers the server by hand. Application logins never get this (user_create.sh,
# person_grant.sh give ro/rw/owner on single databases). The role is not part of databases/postgresql.yaml
# and apply_declared.sh does not touch it.
#
# Nothing is written to Vault. The password is typed in at the prompt of psql (\password): it is asked twice,
# hashed by psql and never shows up in the process list, a file or the log. Keep it in your password manager.
#
# Idempotent: an existing role keeps its password and only gets the attributes it is missing (LOGIN, SUPERUSER).
# The prompt appears for a new role, for "reset", and for an existing role that has no password yet.
#
# Usage: superuser_create.sh [--dry-run] <username> [reset]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly MAX_NAME_LENGTH=63
readonly STATE_MISSING=""
readonly ROLE_COMPLETE="t"

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

# The name reaches the SQL as a psql variable (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v user_name="$USER_NAME" "$@"
}

# Prints "<can log in and is superuser>|<has a password>" as t/f, or nothing if the role does not exist
read_role_state() {
  psql_admin --no-align --tuples-only <<'SQL'
SELECT (rolcanlogin AND rolsuper) || '|' || (rolpassword IS NOT NULL)
FROM pg_authid
WHERE rolname = :'user_name'
SQL
}

# \password asks twice without echo and sends only the hash; the name is validated, so :user_name is safe here
ask_password() {
  [[ -t 0 ]] || die "a terminal is needed to ask for the password of $USER_NAME"
  log "Password for $USER_NAME:"
  psql_admin <<<'\password :user_name'
}

# ensure_role_attributes <state>: creates the role or adds the missing attributes
ensure_role_attributes() {
  local state=$1
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] ensured: login role $USER_NAME with SUPERUSER (not executed)"
  elif [[ $state == "$STATE_MISSING" ]]; then
    psql_admin <<<'CREATE ROLE :"user_name" WITH LOGIN SUPERUSER;'
    log "created: login role $USER_NAME with SUPERUSER"
  else
    psql_admin <<<'ALTER ROLE :"user_name" WITH LOGIN SUPERUSER;'
    log "updated: login role $USER_NAME now has LOGIN and SUPERUSER"
  fi
}

ensure_password() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: password of $USER_NAME would be asked (not executed)"
  else
    ask_password
    log "updated: password of $USER_NAME"
  fi
}

is_password_needed() {
  local state=$1
  [[ $RESET == true || $state == "$STATE_MISSING" || $state == *"|f" ]]
}

main() {
  parse_arguments "$@"
  require_commands sudo psql

  local state
  state=$(read_role_state)

  if [[ ${state%%|*} == "$ROLE_COMPLETE" ]]; then
    log "unchanged: login role $USER_NAME is a superuser"
  else
    ensure_role_attributes "$state"
  fi

  if is_password_needed "$state"; then
    ensure_password
  else
    log "unchanged: password of $USER_NAME kept ('reset' sets a new one)"
  fi
}

main "$@"
