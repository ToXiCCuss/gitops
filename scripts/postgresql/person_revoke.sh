#!/usr/bin/env bash
# Takes access away from a personal login created by person_grant.sh.
#
# With a database the login leaves <db>_role_ro, _rw and _owner and keeps its access to all other databases.
# Without a database the login does not exist afterwards: its sessions are terminated and it is dropped.
# A login owns nothing (it is only a member of the roles), so nothing has to be handed over before the drop.
#
# Idempotent: a missing login or missing access is reported as unchanged. The password in Vault
# (databases/postgresql/<username>) is deleted first when the login goes, whether the login still exists
# or not, so a repeated run also cleans up an old leftover. The delete needs the current policy of
# scripts/vault/configure-vault-databases.ps1. The script only touches logins that person_grant.sh created
# itself, so it cannot drop an application login like shop_owner or a role like postgres.
#
# Usage: person_revoke.sh [--dry-run] <username> [<database_name>]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# PostgreSQL identifiers have 63 bytes, "<db>_role_owner" has to fit
readonly MAX_NAME_LENGTH=52
# The role comment that person_grant.sh puts on its logins, both scripts have to agree on it
readonly PERSON_MARKER="gitops: person login"

LOGIN=""
DB_NAME=""
ROLE_RO=""
ROLE_RW=""
ROLE_OWNER=""

usage() {
  log "Usage: $0 [--dry-run] <username> [<database_name>]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  parse_options "$@"
  ((${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2)) || usage

  LOGIN=${POSITIONAL[0]}
  validate_name "username" "$LOGIN" "$MAX_NAME_LENGTH"

  DB_NAME=${POSITIONAL[1]:-}
  if [[ -n $DB_NAME ]]; then
    validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
    ROLE_RO="${DB_NAME}_role_ro"
    ROLE_RW="${DB_NAME}_role_rw"
    ROLE_OWNER="${DB_NAME}_role_owner"
  fi
}

# The names reach the SQL as psql variables (:"x" is an identifier, :'x' a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 \
    -v login="$LOGIN" -v role_ro="$ROLE_RO" -v role_rw="$ROLE_RW" -v role_owner="$ROLE_OWNER" \
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

login_exists() {
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'login'")" ]]
}

is_person_login() {
  [[ -n "$(query_value "SELECT 1 FROM pg_roles WHERE rolname = :'login' AND shobj_description(oid, 'pg_authid') = :'person_marker'")" ]]
}

# Checked before the Vault entry is deleted, so the entry of an application login is never touched
require_person_login_or_absent() {
  if login_exists; then
    is_person_login ||
      die "$LOGIN exists but was not created by person_grant.sh, so it is left alone"
  fi
}

ensure_access_revoked() {
  local current
  current=$(query_value "
    SELECT string_agg(b.rolname, ' ' ORDER BY b.rolname)
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.member
    JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolname = :'login' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')")

  if [[ -z $current ]]; then
    log "unchanged: $LOGIN has no access to $DB_NAME"
  else
    apply_sql revoked "access of $LOGIN to $DB_NAME (was: $current)" <<'SQL'
SELECT format('REVOKE %I FROM %I', b.rolname, :'login')
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.member
JOIN pg_roles b ON b.oid = m.roleid
WHERE r.rolname = :'login' AND b.rolname IN (:'role_ro', :'role_rw', :'role_owner')
\gexec
SQL
  fi
}

ensure_login_absent() {
  require_vault_access
  ensure_vault_entry_absent "postgresql/$LOGIN"

  if login_exists; then
    apply_sql terminated "sessions of $LOGIN" <<'SQL'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = :'login' AND pid <> pg_backend_pid();
SQL
    apply_sql dropped "login $LOGIN" <<<'DROP ROLE :"login";'
  else
    log "unchanged: login $LOGIN does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo psql
  require_person_login_or_absent

  if [[ -n $DB_NAME ]]; then
    ensure_access_revoked
  else
    ensure_login_absent
  fi
}

main "$@"
