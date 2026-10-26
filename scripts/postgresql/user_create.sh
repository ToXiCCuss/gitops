#!/usr/bin/env bash
# Ensures a login <database_name>_<username> that is a member of exactly one role of the database
# (<db>_role_ro, _rw or _owner, created by db_create.sh).
#
# Idempotent: an existing user keeps its password and only gets the role membership and privileges
# it is missing. The password of a newly created user goes to Vault
# (databases/postgresql/<db>_<username>) and is never printed (user_password.sh sets a new one).
#
# Usage: user_create.sh [--dry-run] <database_name> <username> <role_type: ro|rw|owner>
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# PostgreSQL identifiers have 63 bytes, "<db>_<username>" and "<db>_role_owner" have to fit
readonly MAX_NAME_LENGTH=52

DB_NAME=""
FULL_USER=""
TARGET_ROLE=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <database_name> <username> <role_type: ro|rw|owner>"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 3)) || usage

  DB_NAME=${POSITIONAL[0]}
  validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
  validate_name "username" "${POSITIONAL[1]}" "$MAX_NAME_LENGTH"
  FULL_USER="${DB_NAME}_${POSITIONAL[1]}"
  ROLE_RO="${DB_NAME}_role_ro"
  ROLE_RW="${DB_NAME}_role_rw"
  ROLE_OWNER="${DB_NAME}_role_owner"

  case ${POSITIONAL[2]} in
  ro) TARGET_ROLE=$ROLE_RO ;;
  rw) TARGET_ROLE=$ROLE_RW ;;
  owner) TARGET_ROLE=$ROLE_OWNER ;;
  *) die "invalid role type '${POSITIONAL[2]}', use 'ro', 'rw' or 'owner'" ;;
  esac
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v full_user="$FULL_USER" -v target_role="$TARGET_ROLE" \
    -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" "$@"
}

# query_value <sql>: the first column of the result, empty if there is no row
query_value() {
  psql_admin --no-align --tuples-only <<<"$1"
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

require_database_and_role() {
  [[ -n "$(query_value "SELECT 1 FROM pg_database WHERE datname = :'db_name'")" ]] ||
    die "database $DB_NAME does not exist (db_create.sh creates it)"
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'target_role'")" ]] ||
    die "role $TARGET_ROLE does not exist (db_create.sh creates it)"
}

ensure_user() {
  if [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'full_user'")" ]]; then
    log "unchanged: user $FULL_USER (password kept, user_password.sh sets a new one)"
  else
    local password
    password=$(generate_password)
    # Into Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one
    [[ $DRY_RUN == true ]] || vault_store_password "postgresql/$FULL_USER" "$FULL_USER" "$password"
    apply_sql "$DB_NAME" created "user $FULL_USER" <<SQL
\\set user_password '$password'
CREATE USER :"full_user" WITH PASSWORD :'user_password';
SQL
  fi
}

# The user belongs to exactly one of the three roles of the database, so it moves if it had another one
ensure_role_membership() {
  local current
  current=$(query_value "
    SELECT string_agg(b.rolname, ' ' ORDER BY b.rolname)
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.member
    JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolname = :'full_user' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')")

  if [[ $current == "$TARGET_ROLE" ]]; then
    log "unchanged: $FULL_USER is member of $TARGET_ROLE"
  else
    apply_sql "$DB_NAME" updated "membership of $FULL_USER (was: ${current:-none}, now: $TARGET_ROLE)" <<'SQL'
SELECT format('REVOKE %I FROM %I', b.rolname, :'full_user')
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.member
JOIN pg_roles b ON b.oid = m.roleid
WHERE r.rolname = :'full_user' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')
  AND b.rolname <> :'target_role'
\gexec
GRANT :"target_role" TO :"full_user";
SQL
  fi
}

# Grants and default privileges can be repeated without effect, so they are applied on every run
apply_role_privileges() {
  apply_sql "$DB_NAME" applied "privileges of the roles and objects created by $FULL_USER" <<'SQL'
-- Roles have access to the existing objects in the public schema
GRANT USAGE ON SCHEMA public TO :"role_ro", :"role_rw", :"role_owner";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO :"role_ro";
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO :"role_ro";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"role_rw";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"role_rw";
GRANT ALL ON ALL TABLES IN SCHEMA public TO :"role_owner";
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO :"role_owner";

-- If this user creates tables in the future, the roles get access to them
ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT SELECT ON TABLES TO :"role_ro";
ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT SELECT ON SEQUENCES TO :"role_ro";

ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"role_rw";
ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT USAGE, SELECT ON SEQUENCES TO :"role_rw";

ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT ALL ON TABLES TO :"role_owner";
ALTER DEFAULT PRIVILEGES FOR ROLE :"full_user" GRANT ALL ON SEQUENCES TO :"role_owner";
SQL
}

main() {
  parse_arguments "$@"
  require_commands sudo psql openssl
  require_vault_access
  require_database_and_role

  ensure_user
  ensure_role_membership
  apply_role_privileges
  log "Done: $FULL_USER"
}

main "$@"
