#!/usr/bin/env bash
# Ensures the login role restic-backup uses for the logical backups (the name "databasus" is historic, Databasus is gone).
#
# pg_read_all_data is a predefined role of the whole cluster: SELECT on all tables, views and
# sequences in ALL databases and schemas (also the ones created later), nothing else. One role
# is enough for the complete DBMS. Do not add it to the application users of user_create.sh,
# they would be able to read every database.
#
# pg_read_all_data does not include the right to connect. db_create.sh revokes CONNECT from PUBLIC,
# so the role gets CONNECT on every existing database here (db_create.sh does it for new ones).
# Run the script again after databases were created in another way.
#
# Idempotent: an existing role keeps its password and only gets the grants it is missing. The password of a
# new role goes to Vault (databases/postgresql/<username>) and is never printed; "reset" sets a new one.
# Vault is written first, so an unreachable Vault stops the script before anything is changed.
#
# Usage: backup_user_create.sh [--dry-run] [username] [reset]     (default username: databasus)
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly DEFAULT_USER_NAME="databasus"
readonly MAX_NAME_LENGTH=63

RESET=false
USER_NAME="$DEFAULT_USER_NAME"

usage() {
  log "Usage: $0 [--dry-run] [username] [reset]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} <= 2)) || usage

  USER_NAME=${POSITIONAL[0]:-$DEFAULT_USER_NAME}
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

role_exists() {
  [[ -n "$(psql_admin --no-align --tuples-only <<<"SELECT 1 FROM pg_roles WHERE rolname = :'user_name'")" ]]
}

# apply_new_password <CREATE|ALTER> <outcome>: Vault first, then the role gets the same password
apply_new_password() {
  local statement=$1 outcome=$2 password
  password=$(generate_password)
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: login role $USER_NAME (not executed)"
  else
    vault_store_password "postgresql/$USER_NAME" "$USER_NAME" "$password"
    psql_admin <<SQL
\\set user_password '$password'
$statement ROLE :"user_name" LOGIN PASSWORD :'user_password';
SQL
    log "$outcome: login role $USER_NAME"
  fi
}

ensure_login_role() {
  if ! role_exists; then
    apply_new_password CREATE created
  elif [[ $RESET == true ]]; then
    apply_new_password ALTER updated
  else
    log "unchanged: login role $USER_NAME (password kept, 'reset' sets a new one)"
  fi
}

# Grants can be repeated without effect, so they are applied on every run
apply_backup_privileges() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] applied: pg_read_all_data and CONNECT on all databases for $USER_NAME (not executed)"
  else
    psql_admin <<'SQL'
SET client_min_messages = warning;
GRANT pg_read_all_data TO :"user_name";

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', datname, :'user_name')
FROM pg_database
WHERE datallowconn AND NOT datistemplate
\gexec
SQL
    log "applied: $USER_NAME can connect to all databases and read them (pg_read_all_data)"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql openssl
  require_vault_access

  ensure_login_role
  apply_backup_privileges
}

main "$@"
