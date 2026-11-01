#!/usr/bin/env bash
# Prints the current PostgreSQL state in the format of databases/postgresql.yaml (apply_declared.sh reads it), so the
# first file comes from the real state and not from memory. Read only.
#
# A database without the roles of db_create.sh gets a comment: applying it would change its privileges, so check it
# before it stays in the file. A login that does not follow the name <db>_<name> gets a comment too and is not listed.
#
# Usage: export_declared.sh > databases/postgresql.yaml
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# The role comment that marks personal logins, person_grant.sh and person_revoke.sh use the same text
readonly PERSON_MARKER="gitops: person login"
readonly LOGIN_ROLE_PATTERN='^(.+)_role_(ro|rw|owner)$'

declare -A OWNER_ROLE_EXISTS=()
declare -A DATABASE_LOGINS=()
declare -A DATABASE_NOTES=()
declare -A PERSON_ACCESS=()
PERSONS=()

usage() {
  log "Usage: $0"
  exit "$EXIT_USAGE"
}

psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v person_marker="$PERSON_MARKER" "$@"
}

# query_lines <sql>: one line per row, the columns separated by a tab
query_lines() {
  psql_admin --no-align --tuples-only --field-separator=$'\t' <<<"$1"
}

# add_membership <login> <role> <is person: t|f>: sorts one membership into the logins of a database or the access of a person
add_membership() {
  local database role_type
  if [[ $2 =~ $LOGIN_ROLE_PATTERN ]]; then
    database=${BASH_REMATCH[1]}
    role_type=${BASH_REMATCH[2]}
    if [[ $3 == t ]]; then
      PERSON_ACCESS["$1"]+="$database $role_type"$'\n'
    elif [[ $1 == "${database}_owner" ]]; then
      :
    elif [[ $1 == "${database}_"* ]]; then
      DATABASE_LOGINS["$database"]+="${1#"${database}_"} $role_type"$'\n'
    else
      DATABASE_NOTES["$database"]+="# the login $1 (role $role_type) is not named ${database}_<name> and is not listed"$'\n'
    fi
  fi
}

collect_state() {
  local owner_roles memberships persons login role is_person
  owner_roles=$(query_lines "SELECT rolname FROM pg_roles WHERE rolname ~ '_role_owner\$'")
  while read -r role; do
    if [[ -n $role ]]; then
      OWNER_ROLE_EXISTS["${role%_role_owner}"]=1
    fi
  done <<<"$owner_roles"

  memberships=$(query_lines "SELECT r.rolname, b.rolname,
      coalesce(shobj_description(r.oid, 'pg_authid') = :'person_marker', false)
    FROM pg_roles r JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolcanlogin AND b.rolname ~ '_role_(ro|rw|owner)\$' ORDER BY 1, 2")
  while IFS=$'\t' read -r login role is_person; do
    if [[ -n $login ]]; then
      add_membership "$login" "$role" "$is_person"
    fi
  done <<<"$memberships"

  persons=$(query_lines "SELECT rolname FROM pg_roles WHERE rolcanlogin AND shobj_description(oid, 'pg_authid') = :'person_marker' ORDER BY rolname")
  while read -r login; do
    if [[ -n $login ]]; then
      PERSONS+=("$login")
    fi
  done <<<"$persons"
}

print_database() {
  local entry
  if [[ -z ${OWNER_ROLE_EXISTS[$1]+created} ]]; then
    echo "  # $1 was not created by db_create.sh: applying it changes its privileges, check it first"
  fi
  if [[ -n ${DATABASE_NOTES[$1]+noted} ]]; then
    while read -r entry; do
      [[ -z $entry ]] || echo "  $entry"
    done <<<"${DATABASE_NOTES[$1]}"
  fi
  if [[ -z ${DATABASE_LOGINS[$1]+listed} ]]; then
    echo "  $1: {}"
  else
    echo "  $1:"
    echo "    logins:"
    while read -r entry; do
      [[ -z $entry ]] || echo "      ${entry% *}: ${entry#* }"
    done <<<"${DATABASE_LOGINS[$1]}"
  fi
}

print_person() {
  local entry
  if [[ -z ${PERSON_ACCESS[$1]+granted} ]]; then
    echo "  $1: {}"
  else
    echo "  $1:"
    while read -r entry; do
      [[ -z $entry ]] || echo "    ${entry% *}: ${entry#* }"
    done <<<"${PERSON_ACCESS[$1]}"
  fi
}

print_state() {
  local databases database person
  databases=$(query_lines "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname")
  echo "# Declared state of the PostgreSQL on docker01, applied by scripts/postgresql/apply_declared.sh."
  echo "databases:"
  while read -r database; do
    [[ -z $database ]] || print_database "$database"
  done <<<"$databases"

  if ((${#PERSONS[@]} == 0)); then
    echo "people: {}"
  else
    echo "people:"
    for person in "${PERSONS[@]}"; do
      print_person "$person"
    done
  fi
}

main() {
  (($# == 0)) || usage
  require_commands sudo psql

  collect_state
  print_state
}

main "$@"
