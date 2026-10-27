#!/usr/bin/env bash
# Ensures the personal login <username> and, if a database is given, its read-only or read-write access to it.
#
# One login serves many databases: every run sets the access to a single database, so <username> can be
# 'ro' in one database and 'rw' in another. The access is the membership in <db>_role_ro or <db>_role_rw
# (created by db_create.sh), a person is never made owner. Without a database only the login is ensured,
# it has no access until a later run adds one (user_create.sh <username> forwards here).
#
# Idempotent: an existing login keeps its password and only gets the membership it is missing. The password
# of a newly created login goes to Vault (databases/postgresql/<username>) and is never printed
# (user_password.sh sets a new one). The script only touches logins it created itself (marked with a role
# comment), so it cannot change an application login like shop_owner or a role like postgres.
#
# Usage: person_grant.sh [--dry-run] <username> [<database_name> <role_type: ro|rw>]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# PostgreSQL identifiers have 63 bytes, "<db>_role_owner" has to fit
readonly MAX_NAME_LENGTH=52
# The role comment that marks its logins, person_revoke.sh checks the same text
readonly PERSON_MARKER="gitops: person login"

LOGIN=""
DB_NAME=""
TARGET_ROLE=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <username> [<database_name> <role_type: ro|rw>]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} == 1 || ${#POSITIONAL[@]} == 3)) || usage

  LOGIN=${POSITIONAL[0]}
  validate_name "username" "$LOGIN" "$MAX_NAME_LENGTH"

  if ((${#POSITIONAL[@]} == 3)); then
    DB_NAME=${POSITIONAL[1]}
    validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
    ROLE_RO="${DB_NAME}_role_ro"
    ROLE_RW="${DB_NAME}_role_rw"
    ROLE_OWNER="${DB_NAME}_role_owner"

    case ${POSITIONAL[2]} in
    ro) TARGET_ROLE=$ROLE_RO ;;
    rw) TARGET_ROLE=$ROLE_RW ;;
    *) die "invalid role type '${POSITIONAL[2]}', use 'ro' or 'rw' (owner access is the login ${DB_NAME}_owner of db_create.sh)" ;;
    esac
  fi
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v db_name="$DB_NAME" -v login="$LOGIN" -v target_role="$TARGET_ROLE" \
    -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" \
    -v person_marker="$PERSON_MARKER" "$@"
}

# query_value <sql>: the first column of the result, empty if there is no row
query_value() {
  psql_admin --no-align --tuples-only <<<"$1"
}

# apply_sql <outcome> <resource>: runs the SQL from stdin, or only reports it with --dry-run
apply_sql() {
  local outcome=$1 resource=$2
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    psql_admin -d postgres
    log "$outcome: $resource"
  fi
}

require_database_and_role() {
  [[ -n "$(query_value "SELECT 1 FROM pg_database WHERE datname = :'db_name'")" ]] ||
    die "database $DB_NAME does not exist (db_create.sh creates it)"
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'target_role'")" ]] ||
    die "role $TARGET_ROLE does not exist (db_create.sh creates it)"
}

login_exists() {
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'login'")" ]]
}

is_person_login() {
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'login' AND shobj_description(oid, 'pg_authid') = :'person_marker'")" ]]
}

# Vault first: if that fails nothing was created, and a rerun after a later failure just generates a new one.
# The user is created in one transaction with its marker, so a failed run leaves no unmarked login behind.
create_login() {
  local password
  password=$(generate_password)
  [[ $DRY_RUN == true ]] || vault_store_password "postgresql/$LOGIN" "$LOGIN" "$password"
  apply_sql created "login $LOGIN" <<SQL
\\set user_password '$password'
BEGIN;
CREATE USER :"login" WITH PASSWORD :'user_password';
COMMENT ON ROLE :"login" IS :'person_marker';
COMMIT;
SQL
}

ensure_login() {
  if login_exists; then
    is_person_login ||
      die "$LOGIN exists but was not created by person_grant.sh, so it is left alone"
    log "unchanged: login $LOGIN (password kept, user_password.sh sets a new one)"
  else
    create_login
  fi
}

# The login belongs to at most one of the three roles of the database, so it moves if it had another one
ensure_role_membership() {
  local current outcome=updated
  current=$(query_value "
    SELECT string_agg(b.rolname, ' ' ORDER BY b.rolname)
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.member
    JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolname = :'login' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')")

  if [[ $current == "$TARGET_ROLE" ]]; then
    log "unchanged: $LOGIN is member of $TARGET_ROLE"
  else
    [[ -n $current ]] || outcome=created
    apply_sql "$outcome" "membership of $LOGIN (was: ${current:-none}, now: $TARGET_ROLE)" <<'SQL'
SELECT format('REVOKE %I FROM %I', b.rolname, :'login')
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.member
JOIN pg_roles b ON b.oid = m.roleid
WHERE r.rolname = :'login' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')
  AND b.rolname <> :'target_role'
\gexec
GRANT :"target_role" TO :"login";
SQL
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql openssl
  require_vault_access
  if [[ -n $DB_NAME ]]; then
    require_database_and_role
  fi

  ensure_login
  if [[ -n $DB_NAME ]]; then
    ensure_role_membership
    log "Done: $LOGIN on $DB_NAME as ${TARGET_ROLE##*_}"
  else
    log "Done: $LOGIN without database access (person_grant.sh $LOGIN <database> <ro|rw> adds it)"
  fi
}

main "$@"
