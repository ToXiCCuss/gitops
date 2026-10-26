#!/usr/bin/env bash
# Ensures the login <database_name>_<username> does not exist: its sessions are terminated, its objects
# in the database go to <db>_role_owner, its privileges are removed and the login is dropped.
#
# Idempotent: a missing login is reported as unchanged. The password in Vault (databases/postgresql/<login>) is
# deleted first, whether the login still exists or not, so a repeated run also cleans up an old leftover.
# The delete needs the current policy of scripts/vault/configure-vault-databases.ps1.
#
# Usage: user_delete.sh [--dry-run] <database_name> <username>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# PostgreSQL identifiers have 63 bytes, "<db>_<username>" and "<db>_role_owner" have to fit
readonly MAX_NAME_LENGTH=52

DB_NAME=""
FULL_USER=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> <username>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  validate_name "username" "${POSITIONAL[1]}" "$MAX_NAME_LENGTH"
  FULL_USER="${DB_NAME}_${POSITIONAL[1]}"
  ROLE_OWNER="${DB_NAME}_role_owner"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v full_user="$FULL_USER" -v role_owner="$ROLE_OWNER" "$@"
}

# query_exists <sql>: true if the query returns a row
query_exists() {
  [[ -n "$(psql_admin --no-align --tuples-only <<<"$1")" ]]
}

# apply_sql <database> <outcome> <resource>: runs the SQL from stdin, or only reports it with --dry-run
apply_sql() {
  local database=$1 outcome=$2 resource=$3
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    psql_admin -d "$database"
    log "$outcome: $resource"
  fi
}

# The default privileges that user_create.sh sets FOR ROLE the login are objects that depend on it, so they
# have to go before DROP ROLE. Its tables are handed to the owner role first, nothing is dropped with them.
release_objects_of_user() {
  if query_exists "SELECT 1 FROM pg_database WHERE datname = :'db_name'"; then
    apply_sql "$DB_NAME" updated "objects and privileges of $FULL_USER in $DB_NAME" <<'SQL'
REASSIGN OWNED BY :"full_user" TO :"role_owner";
DROP OWNED BY :"full_user";
SQL
  fi
}

ensure_user_absent() {
  if query_exists "SELECT 1 FROM pg_roles WHERE rolname = :'full_user'"; then
    apply_sql postgres terminated "sessions of $FULL_USER" <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = :'full_user' AND pid <> pg_backend_pid();
SQL
    release_objects_of_user
    apply_sql postgres dropped "login $FULL_USER" <<<'DROP ROLE :"full_user";'
  else
    log "unchanged: login $FULL_USER does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql
  require_vault_access

  ensure_vault_entry_absent "postgresql/$FULL_USER"
  ensure_user_absent
}

main "$@"
