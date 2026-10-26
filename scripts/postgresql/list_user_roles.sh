#!/usr/bin/env bash
# Lists the PostgreSQL logins with their roles, who may connect to which database and, per database, the
# logins that belong to its roles (<db>_role_ro, _rw, _owner). Read only.
#
# Usage: list_user_roles.sh
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly SEPARATOR="----------------------------------------------------------------------"

usage() {
  log "Usage: $0"
  exit "$EXIT_USAGE"
}

psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 "$@"
}

print_logins() {
  echo "$SEPARATOR"
  echo "PostgreSQL logins and their roles (cluster-wide):"
  psql_admin --tuples-only <<'SQL'
SELECT
    r.rolname AS login,
    ARRAY(SELECT b.rolname
          FROM pg_auth_members m
          JOIN pg_roles b ON b.oid = m.roleid
          WHERE m.member = r.oid) AS member_of
FROM pg_roles r
WHERE r.rolcanlogin
ORDER BY r.rolname;
SQL
}

print_database_access() {
  echo "$SEPARATOR"
  echo "Database access (CONNECT):"
  psql_admin --tuples-only <<'SQL'
SELECT
    datname,
    pg_catalog.pg_get_userbyid(datdba) AS owner,
    datacl
FROM pg_database
WHERE NOT datistemplate
ORDER BY datname;
SQL
  echo "Note: 'datacl' is the access control list of the database, format {role=privileges/grantor,...}"
}

# The logins that are members of one of the roles of the database
print_logins_per_database() {
  local databases database
  echo "$SEPARATOR"
  echo "Logins per database (members of <db>_role_ro, _rw, _owner):"
  databases=$(psql_admin --no-align --tuples-only <<<"SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname")
  while read -r database; do
    [[ -n $database ]] || continue
    echo "Database: $database"
    psql_admin --tuples-only -v db_name="$database" <<'SQL'
SELECT
    r.rolname AS login,
    ARRAY(SELECT b.rolname
          FROM pg_auth_members m2
          JOIN pg_roles b ON b.oid = m2.roleid
          WHERE m2.member = r.oid AND b.rolname IN (:'db_name' || '_role_ro', :'db_name' || '_role_rw', :'db_name' || '_role_owner')) AS roles
FROM pg_roles r
WHERE r.rolcanlogin
  AND EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles b ON b.oid = m.roleid
    WHERE m.member = r.oid AND b.rolname IN (:'db_name' || '_role_ro', :'db_name' || '_role_rw', :'db_name' || '_role_owner'))
ORDER BY r.rolname;
SQL
  done <<<"$databases"
}

main() {
  (($# == 0)) || usage
  require_commands sudo psql

  print_logins
  print_database_access
  print_logins_per_database
}

main "$@"
