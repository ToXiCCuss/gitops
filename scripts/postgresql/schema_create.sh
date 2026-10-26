#!/usr/bin/env bash
# Ensures a schema in a database that db_create.sh made: the schema belongs to <db>_role_owner and the
# three roles (<db>_role_ro, _rw, _owner) get their privileges on it, also on the tables created later.
#
# Idempotent: an existing schema is kept (and keeps its owner), the grants and default privileges can be
# repeated without effect, so they are applied on every run.
#
# Usage: schema_create.sh [--dry-run] <database_name> <schema_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 63 bytes of a PostgreSQL identifier
readonly MAX_DATABASE_NAME_LENGTH=52
readonly MAX_SCHEMA_NAME_LENGTH=63
readonly RESERVED_SCHEMA_PREFIX="pg_"

DB_NAME=""
SCHEMA_NAME=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> <schema_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 2)) || usage

  DB_NAME=${POSITIONAL[0]}
  SCHEMA_NAME=${POSITIONAL[1]}
  validate_name "database name" "$DB_NAME" "$MAX_DATABASE_NAME_LENGTH"
  validate_name "schema name" "$SCHEMA_NAME" "$MAX_SCHEMA_NAME_LENGTH"
  [[ $SCHEMA_NAME != "${RESERVED_SCHEMA_PREFIX}"* && $SCHEMA_NAME != information_schema ]] ||
    die "$SCHEMA_NAME is reserved for PostgreSQL"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v schema_name="$SCHEMA_NAME" \
    -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" "$@"
}

# query_exists <sql> [psql arguments]: true if the query returns a row
query_exists() {
  local sql=$1
  shift
  [[ -n "$(psql_admin --no-align --tuples-only "$@" <<<"$sql")" ]]
}

# apply_sql <outcome> <resource>: runs the SQL from stdin in the database, or only reports it with --dry-run
apply_sql() {
  local outcome=$1 resource=$2
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    psql_admin -d "$DB_NAME"
    log "$outcome: $resource"
  fi
}

require_database_and_owner_role() {
  query_exists "SELECT 1 FROM pg_database WHERE datname = :'db_name'" ||
    die "database $DB_NAME does not exist (db_create.sh creates it)"
  query_exists "SELECT 1 FROM pg_roles WHERE rolname = :'role_owner'" ||
    die "role $ROLE_OWNER does not exist (db_create.sh creates it)"
}

ensure_schema() {
  if query_exists "SELECT 1 FROM information_schema.schemata WHERE schema_name = :'schema_name'" -d "$DB_NAME"; then
    log "unchanged: schema $SCHEMA_NAME"
  else
    apply_sql created "schema $SCHEMA_NAME" <<<'CREATE SCHEMA :"schema_name" AUTHORIZATION :"role_owner";'
  fi
}

apply_schema_privileges() {
  apply_sql applied "privileges of the roles on $SCHEMA_NAME" <<'SQL'
GRANT CREATE ON SCHEMA :"schema_name" TO :"role_owner";
GRANT USAGE ON SCHEMA :"schema_name" TO :"role_ro", :"role_rw", :"role_owner";

-- Existing objects in the schema
GRANT SELECT ON ALL TABLES IN SCHEMA :"schema_name" TO :"role_ro";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"role_ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA :"schema_name" TO :"role_rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"role_rw";
GRANT ALL ON ALL TABLES IN SCHEMA :"schema_name" TO :"role_owner";
GRANT ALL ON ALL SEQUENCES IN SCHEMA :"schema_name" TO :"role_owner";

-- Objects created later
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT SELECT ON SEQUENCES TO :"role_ro";

ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";

ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT ALL ON TABLES TO :"role_owner";
ALTER DEFAULT PRIVILEGES IN SCHEMA :"schema_name" GRANT ALL ON SEQUENCES TO :"role_owner";

ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" IN SCHEMA :"schema_name" GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" IN SCHEMA :"schema_name" GRANT SELECT ON SEQUENCES TO :"role_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" IN SCHEMA :"schema_name" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" IN SCHEMA :"schema_name" GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";
SQL
}

main() {
  parse_arguments "$@"
  require_commands sudo psql
  require_database_and_owner_role

  ensure_schema
  apply_schema_privileges
  log "Done: $DB_NAME.$SCHEMA_NAME"
}

main "$@"
