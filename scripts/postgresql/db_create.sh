#!/usr/bin/env bash
# Ensures a PostgreSQL database with its three roles (<db>_role_ro, _rw, _owner) and the login <db>_owner.
#
# Idempotent: a missing part is created, an existing part is left as it is, so a run that was aborted
# can simply be started again. The password of a newly created <db>_owner goes to Vault
# (databases/postgresql/<db>_owner) and is never printed; an existing user keeps its password
# (user_password.sh sets a new one).
#
# Usage: db_create.sh [--dry-run] <database_name>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 63 bytes of a PostgreSQL identifier
readonly MAX_NAME_LENGTH=52
readonly BACKUP_ROLE="databasus"

DB_NAME=""
DB_USER=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 1)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  DB_USER="${DB_NAME}_owner"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v db_user="$DB_USER" \
    -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" \
    -v backup_role="$BACKUP_ROLE" "$@"
}

# query_exists <sql>: true if the query returns a row
query_exists() {
  [[ -n "$(psql_admin --no-align --tuples-only <<<"$1")" ]]
}

role_exists() {
  query_exists "SELECT 1 FROM pg_roles WHERE rolname = :'$1'"
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

ensure_database() {
  if query_exists "SELECT 1 FROM pg_database WHERE datname = :'db_name'"; then
    log "unchanged: database $DB_NAME"
  else
    apply_sql postgres created "database $DB_NAME" <<<'CREATE DATABASE :"db_name";'
  fi
}

# ensure_role <psql variable holding the role name> <role name>
ensure_role() {
  if role_exists "$1"; then
    log "unchanged: role $2"
  else
    apply_sql postgres created "role $2" <<<"CREATE ROLE :\"$1\";"
  fi
}

# Grants and default privileges can be repeated without effect, so they are applied on every run
apply_role_privileges() {
  apply_sql "$DB_NAME" applied "privileges of the roles in $DB_NAME" <<'SQL'
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE :"db_name" FROM PUBLIC;

ALTER SCHEMA public OWNER TO :"role_owner";

GRANT USAGE ON SCHEMA public TO :"role_ro", :"role_rw", :"role_owner";
GRANT CREATE ON SCHEMA public TO :"role_owner";

ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES GRANT SELECT ON SEQUENCES TO :"role_ro";

ALTER DEFAULT PRIVILEGES GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";

ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO :"role_owner";
ALTER DEFAULT PRIVILEGES GRANT ALL ON SEQUENCES TO :"role_owner";

-- Default privileges for objects created by the owner role
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" GRANT SELECT ON SEQUENCES TO :"role_ro";

ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"role_owner" GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";

REVOKE CONNECT ON DATABASE :"db_name" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db_name" TO :"role_ro", :"role_rw", :"role_owner";
SQL
}

# The user is created in one transaction with its default privileges, so a failed run leaves no half-configured user
ensure_owner_user() {
  if role_exists db_user; then
    log "unchanged: user $DB_USER (password kept, user_password.sh sets a new one)"
  else
    local password
    password=$(generate_password)
    # Into Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one
    [[ $DRY_RUN == true ]] || vault_store_password "postgresql/$DB_USER" "$DB_USER" "$password"
    apply_sql "$DB_NAME" created "user $DB_USER" <<SQL
\\set user_password '$password'
BEGIN;
CREATE USER :"db_user" WITH PASSWORD :'user_password';
GRANT :"role_owner" TO :"db_user";

ALTER DEFAULT PRIVILEGES FOR ROLE :"db_user" GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"db_user" GRANT SELECT ON SEQUENCES TO :"role_ro";

ALTER DEFAULT PRIVILEGES FOR ROLE :"db_user" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"db_user" GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";
COMMIT;
SQL
  fi
}

# The backup role (backup_user_create.sh) needs CONNECT on every database, if the role exists
ensure_backup_role_can_connect() {
  apply_sql postgres applied "CONNECT of $BACKUP_ROLE (only if the role exists)" <<'SQL'
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'backup_role')
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = :'backup_role')
\gexec
SQL
}

main() {
  parse_arguments "$@"
  require_commands sudo psql openssl
  require_vault_access

  ensure_database
  ensure_role role_ro "$ROLE_RO"
  ensure_role role_rw "$ROLE_RW"
  ensure_role role_owner "$ROLE_OWNER"
  apply_role_privileges
  ensure_owner_user
  ensure_backup_role_can_connect
  log "Done: $DB_NAME"
}

main "$@"
