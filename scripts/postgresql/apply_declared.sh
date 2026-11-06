#!/usr/bin/env bash
# Ensures the PostgreSQL state that is declared in databases/postgresql.yaml (the databases, their application
# logins and the personal logins with their access). The work is done by the scripts of this folder, so the file
# only says what should exist; nothing depends on any tool besides the host itself.
#
# Idempotent: every part is reported as created, updated or unchanged, an aborted run can be started again.
#   databases and their login <db>_owner     db_create.sh
#   CREATE/TEMPORARY of <db>_role_owner      ownerPrivileges of a database (an app that makes its own schemas, e.g.
#                                            Backstage; granted and, when no longer declared, revoked). With create
#                                            the new schemas of the owner login get USAGE for the ro and rw roles.
#   application logins <db>_<name>           user_create.sh
#   personal logins and their access         person_grant.sh
#   access that is no longer declared        person_revoke.sh (only if the file has the key "people": a personal
#                                            login that is not listed is dropped, a database that is not listed for
#                                            it is taken away)
#   removed databases and logins            db_delete.sh, user_delete.sh (only what the key "removed:" lists, see below)
# A database or an application login that is not declared is only reported. --prune also deletes the undeclared
# databases (db_delete.sh), after you typed the name of each one at the terminal.
#
# The key "removed:" is the only way to delete without a terminal: what it lists is deleted for good (the databases
# with all their data, the logins with their password in Vault), what it does not list is never deleted. The merge
# of the file is the confirmation. A name that is both declared and removed stops the run before anything is changed.
#   removed:
#     databases: [shop]
#     logins:
#       forgejo: [app]        # <database>: [<name>], the login <database>_<name>
#
# Usage: apply_declared.sh [--dry-run] [--prune] [--file <path>] [--pull] [--metrics-file <path>]
#        --dry-run       only report what would be changed
#        --prune         delete the databases that are not declared (asks for each one, needs a terminal)
#        --file          the declared state, default databases/postgresql.yaml of this repository
#        --pull          git pull --ff-only in this repository first (the postgresql-apply timer)
#        --metrics-file  leave the result of the run for the textfile collector of the node_exporter
#                        (gitops_databases_* metrics, see docs/databases.md). Not written by a --dry-run
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<name>_role_owner" has to fit into the 63 bytes of a PostgreSQL identifier
readonly MAX_NAME_LENGTH=52
# The role comment that marks personal logins, person_grant.sh and person_revoke.sh use the same text
readonly PERSON_MARKER="gitops: person login"
# --pull tries the git pull this often, with this pause in between (the unit allows 15 minutes)
readonly PULL_ATTEMPTS=4
readonly PULL_RETRY_SECONDS=30
readonly ACCESS_ROLE_PATTERN='^(.+)_role_(ro|rw)$'
readonly LOGIN_ROLE_PATTERN='^(.+)_role_(ro|rw|owner)$'
# One line per declared item: kind, then up to three fields, "-" for an empty one
# shellcheck disable=SC2016 # a jq program, the \( ) are jq string interpolation and must not expand in bash
readonly RECORDS_FILTER='
  (.databases | to_entries[] | "database\t\(.key)\t-\t-"),
  (.databases | to_entries[] | .key as $database | (.value.ownerPrivileges // [])[]
    | "privilege\t\($database)\t\(. | ascii_upcase)\t-"),
  (.databases | to_entries[] | .key as $database | (.value.logins // {}) | to_entries[]
    | "login\t\($database)\t\(.key)\t\(.value)"),
  ((.people // {}) | to_entries[] | .key as $person | (.value // {}) as $access
    | if ($access | length) == 0 then "person\t\($person)\t-\t-"
      else ($access | to_entries[] | "person\t\($person)\t\(.key)\t\(.value)") end),
  ((.removed.logins // {}) | to_entries[] | .key as $database | (.value // [])[]
    | "removed-login\t\($database)\t\(.)\t-"),
  ((.removed.databases // [])[] | "removed-database\t\(.)\t-\t-")
'
readonly OWNER_LOGIN_NAME="owner"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly REPOSITORY_DIR="$SCRIPT_DIR/../.."

DECLARED_FILE="$REPOSITORY_DIR/databases/postgresql.yaml"
PRUNE=false
PULL=false
METRICS_FILE=""
HAS_PEOPLE_SECTION=false
DECLARED_DATABASES=()
DECLARED_LOGINS=()
DECLARED_PEOPLE=()
REMOVED_DATABASES=()
REMOVED_LOGINS=()
declare -A DECLARED_DATABASE_SET=()
declare -A DECLARED_OWNER_PRIVILEGE_SET=()
declare -A DECLARED_LOGIN_ROLE=()
declare -A DECLARED_PERSON_SET=()
declare -A DECLARED_PERSON_ACCESS=()

usage() {
  log "Usage: $0 [--dry-run] [--prune] [--file <path>] [--pull] [--metrics-file <path>]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local remaining=()
  while (($# > 0)); do
    case $1 in
    --prune) PRUNE=true ;;
    --pull) PULL=true ;;
    --file)
      (($# >= 2)) || usage
      DECLARED_FILE=$2
      shift
      ;;
    --metrics-file)
      (($# >= 2)) || usage
      METRICS_FILE=$2
      shift
      ;;
    *) remaining+=("$1") ;;
    esac
    shift
  done
  parse_options "${remaining[@]}"
  ((${#POSITIONAL[@]} == 0)) || usage
}

# The values reach the SQL as psql variables (:'x' is a literal), never by string concatenation
psql_admin() {
  sudo -u postgres psql --no-psqlrc --quiet -v ON_ERROR_STOP=1 -v person_marker="$PERSON_MARKER" "$@"
}

# query_lines <sql>: one line per row, the columns separated by a tab
query_lines() {
  psql_admin --no-align --tuples-only --field-separator=$'\t' <<<"$1"
}

database_exists() {
  [[ -n "$(psql_admin --no-align --tuples-only -v database="$1" <<<"SELECT 1 FROM pg_database WHERE datname = :'database'")" ]]
}

# run_script <script of this folder> <argument>...: the script gets --dry-run when this run has it. Its stdin is
# closed because the callers read their lists from stdin, a script that read it would eat the rest of the list.
run_script() {
  local script=$1 flags=()
  shift
  if [[ $DRY_RUN == true ]]; then
    flags=(--dry-run)
  fi
  "$SCRIPT_DIR/$script" "${flags[@]}" "$@" </dev/null
}

register_database() {
  validate_name "database name" "$1" "$MAX_NAME_LENGTH"
  DECLARED_DATABASES+=("$1")
  DECLARED_DATABASE_SET["$1"]=1
}

require_declared_database() {
  [[ -n ${DECLARED_DATABASE_SET[$2]+declared} ]] || die "$1 refers to the database $2, which is not declared under 'databases:'"
}

# register_privilege <database> <PRIVILEGE>
register_privilege() {
  local key="$1 $2"
  require_declared_database "ownerPrivileges" "$1"
  case $2 in
  CREATE | TEMPORARY) ;;
  *) die "invalid ownerPrivileges entry '$2' of the database $1, use create or temporary" ;;
  esac
  DECLARED_OWNER_PRIVILEGE_SET["$key"]=1
}

# register_login <database> <name> <role>
register_login() {
  validate_name "login name" "$2" "$MAX_NAME_LENGTH"
  require_declared_database "the login $2" "$1"
  case $3 in
  ro | rw | owner) ;;
  *) die "invalid role '$3' of the login $2 in $1, use ro, rw or owner" ;;
  esac
  DECLARED_LOGINS+=("$1 $2 $3")
  DECLARED_LOGIN_ROLE["$1_$2"]=$3
}

# register_person <person> <database or -> <role or ->
register_person() {
  validate_name "person name" "$1" "$MAX_NAME_LENGTH"
  DECLARED_PERSON_SET["$1"]=1
  DECLARED_PEOPLE+=("$1 $2 $3")
  if [[ $2 != - ]]; then
    require_declared_database "the person $1" "$2"
    case $3 in
    ro | rw) ;;
    *) die "invalid role '$3' of the person $1 in $2, use ro or rw (owner access is the login ${2}_owner)" ;;
    esac
    DECLARED_PERSON_ACCESS["$1:$2"]=$3
  fi
}

# register_removed_database <database>: a database cannot be declared and removed at the same time
register_removed_database() {
  validate_name "removed database name" "$1" "$MAX_NAME_LENGTH"
  [[ -z ${DECLARED_DATABASE_SET[$1]+declared} ]] ||
    die "the database $1 is declared under 'databases:' and listed under 'removed:', keep only one of them"
  REMOVED_DATABASES+=("$1")
}

# register_removed_login <database> <name>: the owner login belongs to the database, db_delete.sh removes it with it
register_removed_login() {
  validate_name "database name of a removed login" "$1" "$MAX_NAME_LENGTH"
  validate_name "removed login name" "$2" "$MAX_NAME_LENGTH"
  [[ $2 != "$OWNER_LOGIN_NAME" ]] ||
    die "the login ${1}_$OWNER_LOGIN_NAME belongs to the database $1 and is removed with it (removed: databases)"
  [[ -z ${DECLARED_LOGIN_ROLE[${1}_$2]+declared} ]] ||
    die "the login ${1}_$2 is declared under 'logins:' and listed under 'removed:', keep only one of them"
  REMOVED_LOGINS+=("$1 $2")
}

load_declared_state() {
  local json records kind first second third
  [[ -f $DECLARED_FILE ]] || die "the declared state $DECLARED_FILE does not exist"
  json=$(yq -c . "$DECLARED_FILE") || die "cannot read $DECLARED_FILE (yq has to be the apt package yq, a wrapper of jq)"
  jq -e '(.databases | type == "object") and (.databases | length > 0)' <<<"$json" >/dev/null ||
    die "$DECLARED_FILE has to declare at least one database under 'databases:'"
  jq -e '(has("people") | not) or (.people | type == "object")' <<<"$json" >/dev/null ||
    die "'people:' in $DECLARED_FILE has to be a map of people (leave the key out to keep personal logins untouched)"
  if jq -e 'has("people")' <<<"$json" >/dev/null; then
    HAS_PEOPLE_SECTION=true
  fi
  jq -e '(.removed // {}) | type == "object" and ((.databases // []) | type == "array") and ((.logins // {}) | type == "object")
    and ((.logins // {}) | to_entries | all(.value == null or (.value | type == "array")))' <<<"$json" >/dev/null ||
    die "'removed:' in $DECLARED_FILE needs 'databases:' as a list and 'logins:' as a map of <database>: [<name>, ...]"

  records=$(jq -r "$RECORDS_FILTER" <<<"$json")
  while IFS=$'\t' read -r kind first second third; do
    case $kind in
    database) register_database "$first" ;;
    privilege) register_privilege "$first" "$second" ;;
    login) register_login "$first" "$second" "$third" ;;
    person) register_person "$first" "$second" "$third" ;;
    removed-login) register_removed_login "$first" "$second" ;;
    removed-database) register_removed_database "$first" ;;
    esac
  done <<<"$records"
}

# In a dry run a database that does not exist yet cannot be inspected, so what depends on it is only announced
database_ready() {
  local is_ready=true
  if [[ $DRY_RUN == true ]] && ! database_exists "$1"; then
    log "[dry-run] skipped: $2 (database $1 would be created first)"
    is_ready=false
  fi
  [[ $is_ready == true ]]
}

ensure_databases() {
  local database
  for database in "${DECLARED_DATABASES[@]}"; do
    run_script db_create.sh "$database"
  done
}

owner_has_privilege() {
  local has_privilege
  has_privilege=$(psql_admin --no-align --tuples-only -v database="$1" -v owner_role="${1}_role_owner" -v privilege="$2" <<<"SELECT coalesce((SELECT has_database_privilege(r.oid, d.oid, :'privilege') FROM pg_roles r, pg_database d WHERE r.rolname = :'owner_role' AND d.datname = :'database'), false)")
  [[ $has_privilege == t ]]
}

# change_owner_privilege <GRANT|REVOKE> <database> <CREATE|TEMPORARY>: format() builds the statement, \gexec runs it
change_owner_privilege() {
  local preposition=TO
  if [[ $1 == REVOKE ]]; then
    preposition=FROM
  fi
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: $1 $3 on $2 for ${2}_role_owner (not executed)"
  else
    psql_admin -v verb="$1" -v preposition="$preposition" -v database="$2" -v owner_role="${2}_role_owner" -v privilege="$3" \
      <<<"SELECT format('%s %s ON DATABASE %I %s %I', :'verb', :'privilege', :'database', :'preposition', :'owner_role') \gexec"
    log "updated: $1 $3 on $2 for ${2}_role_owner"
  fi
}

# The privileges follow the file: a declared one is granted, one that is not declared (any more) is revoked
ensure_owner_privilege() {
  local key="$1 $2" is_declared=false has_privilege=false
  if [[ -n ${DECLARED_OWNER_PRIVILEGE_SET[$key]+declared} ]]; then
    is_declared=true
  fi
  if owner_has_privilege "$1" "$2"; then
    has_privilege=true
  fi
  if [[ $is_declared == true && $has_privilege == false ]]; then
    change_owner_privilege GRANT "$1" "$2"
  elif [[ $is_declared == false && $has_privilege == true ]]; then
    change_owner_privilege REVOKE "$1" "$2"
  elif [[ $is_declared == true ]]; then
    log "unchanged: $2 on $1 for ${1}_role_owner"
  fi
}

# A schema made by the owner login gets USAGE for the ro and rw roles, like the tables in it get their privileges from
# db_create.sh. Default privileges belong to one database, only reach schemas made afterwards and can be repeated,
# so they are applied in the database on every run.
ensure_schema_usage() {
  local key="$1 CREATE"
  if [[ -n ${DECLARED_OWNER_PRIVILEGE_SET[$key]+declared} ]]; then
    if [[ $DRY_RUN == true ]]; then
      log "[dry-run] applied: USAGE on new schemas of $1 for ${1}_role_ro and ${1}_role_rw (not executed)"
    else
      psql_admin -d "$1" -v owner_login="${1}_owner" -v role_ro="${1}_role_ro" -v role_rw="${1}_role_rw" \
        <<<'ALTER DEFAULT PRIVILEGES FOR ROLE :"owner_login" GRANT USAGE ON SCHEMAS TO :"role_ro", :"role_rw"'
      log "applied: USAGE on new schemas of $1 for ${1}_role_ro and ${1}_role_rw"
    fi
  fi
}

ensure_owner_privileges() {
  local database privilege
  for database in "${DECLARED_DATABASES[@]}"; do
    if database_ready "$database" "privileges of ${database}_role_owner"; then
      for privilege in CREATE TEMPORARY; do
        ensure_owner_privilege "$database" "$privilege"
      done
      ensure_schema_usage "$database"
    fi
  done
}

ensure_logins() {
  local entry database name role
  for entry in "${DECLARED_LOGINS[@]}"; do
    read -r database name role <<<"$entry"
    if database_ready "$database" "login ${database}_$name"; then
      run_script user_create.sh "$database" "$name" "$role"
    fi
  done
}

ensure_people() {
  local entry person database role
  for entry in "${DECLARED_PEOPLE[@]}"; do
    read -r person database role <<<"$entry"
    if [[ $database == - ]]; then
      run_script person_grant.sh "$person"
    elif database_ready "$database" "access of $person to $database"; then
      run_script person_grant.sh "$person" "$database" "$role"
    fi
  done
}

# The logins go first, while their database still exists and their objects can be handed to <db>_role_owner. The scripts
# are idempotent, so a login or database that is already gone is only reported as unchanged.
ensure_removed_logins() {
  local entry database name
  for entry in "${REMOVED_LOGINS[@]}"; do
    read -r database name <<<"$entry"
    run_script user_delete.sh "$database" "$name"
  done
}

ensure_removed_databases() {
  local database
  for database in "${REMOVED_DATABASES[@]}"; do
    run_script db_delete.sh "$database"
  done
}

# revoke_access_if_undeclared <login> <role the login is a member of>
revoke_access_if_undeclared() {
  local database access_key
  if [[ $2 =~ $ACCESS_ROLE_PATTERN ]]; then
    database=${BASH_REMATCH[1]}
    access_key="$1:$database"
    if [[ -n ${DECLARED_PERSON_SET[$1]+declared} && -z ${DECLARED_PERSON_ACCESS[$access_key]+declared} ]]; then
      run_script person_revoke.sh "$1" "$database"
    fi
  fi
}

revoke_undeclared_access() {
  local logins roles login role
  logins=$(query_lines "SELECT rolname FROM pg_roles WHERE rolcanlogin AND shobj_description(oid, 'pg_authid') = :'person_marker' ORDER BY rolname")
  while read -r login; do
    if [[ -n $login && -z ${DECLARED_PERSON_SET[$login]+declared} ]]; then
      run_script person_revoke.sh "$login"
    fi
  done <<<"$logins"

  roles=$(query_lines "SELECT r.rolname, b.rolname FROM pg_roles r
    JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolcanlogin AND shobj_description(r.oid, 'pg_authid') = :'person_marker' ORDER BY 1, 2")
  while IFS=$'\t' read -r login role; do
    if [[ -n $login ]]; then
      revoke_access_if_undeclared "$login" "$role"
    fi
  done <<<"$roles"
}

# report_login_if_undeclared <login> <role the login is a member of>: the owner login of a database belongs to it
report_login_if_undeclared() {
  local database role_type
  if [[ $2 =~ $LOGIN_ROLE_PATTERN ]]; then
    database=${BASH_REMATCH[1]}
    role_type=${BASH_REMATCH[2]}
    if [[ -n ${DECLARED_DATABASE_SET[$database]+declared} && $1 != "${database}_owner" && -z ${DECLARED_LOGIN_ROLE[$1]+declared} ]]; then
      log "undeclared: login $1 (role $role_type of $database) is not touched (declare it, or user_delete.sh removes it)"
    fi
  fi
}

report_undeclared_logins() {
  local logins login role
  logins=$(query_lines "SELECT r.rolname, b.rolname FROM pg_roles r
    JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles b ON b.oid = m.roleid
    WHERE r.rolcanlogin AND coalesce(shobj_description(r.oid, 'pg_authid'), '') <> :'person_marker'
      AND b.rolname ~ '_role_(ro|rw|owner)\$' ORDER BY 1, 2")
  while IFS=$'\t' read -r login role; do
    if [[ -n $login ]]; then
      report_login_if_undeclared "$login" "$role"
    fi
  done <<<"$logins"
}

# A deletion needs a person at a terminal, so no timer or pipe can ever prune a database. The answer is read from
# /dev/tty because stdin of the loop that calls this holds the list of databases.
confirm_deletion() {
  local answer=""
  if [[ $DRY_RUN == false ]]; then
    read -r -p "Delete the database $1 and all its data for good? Type its name to confirm: " answer </dev/tty ||
      die "--prune asks for a confirmation and needs a terminal"
    [[ $answer == "$1" ]] || die "not confirmed, the database $1 is kept"
  fi
}

handle_undeclared_database() {
  if [[ $PRUNE == true ]]; then
    confirm_deletion "$1"
    run_script db_delete.sh "$1"
  else
    log "undeclared: database $1 is not touched (declare it, or --prune deletes it after a confirmation)"
  fi
}

report_undeclared_databases() {
  local databases database
  databases=$(query_lines "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY datname")
  while read -r database; do
    if [[ -n $database && -z ${DECLARED_DATABASE_SET[$database]+declared} ]]; then
      handle_undeclared_database "$database"
    fi
  done <<<"$databases"
}

# The checkout of the host is brought up to date before the file is read, so a merge to master reaches the server.
# A short outage of DNS or GitHub is repeated, so it does not end in a failed run (and an alert) until the next hour.
pull_repository() {
  local attempt=1 is_pulled=false
  while [[ $is_pulled == false && $attempt -le $PULL_ATTEMPTS ]]; do
    if git -C "$REPOSITORY_DIR" pull --ff-only >&2; then
      is_pulled=true
    else
      log "git pull failed (attempt $attempt of $PULL_ATTEMPTS)"
      if ((attempt < PULL_ATTEMPTS)); then
        sleep "$PULL_RETRY_SECONDS"
      fi
      attempt=$((attempt + 1))
    fi
  done
  [[ $is_pulled == true ]] ||
    die "git pull failed $PULL_ATTEMPTS times (network, local changes or a diverged branch?), nothing is applied"
}

# The time of the last successful run from the previous metrics file, 0 if there is none
previous_success_time() {
  local previous
  previous=$(sed -n 's/^gitops_databases_last_success_timestamp_seconds //p' "$METRICS_FILE" 2>/dev/null | head -n 1) || true
  echo "${previous:-0}"
}

# render_metrics <exit status of the run>: the result in the format of the textfile collector. A failed run keeps the
# time of the last success, Prometheus alerts when it gets too old
render_metrics() {
  local now last_success apply_success=0 revision
  now=$(date +%s)
  last_success=$(previous_success_time)
  if (($1 == 0)); then
    apply_success=1
    last_success=$now
  fi
  revision=$(git -C "$REPOSITORY_DIR" rev-parse --short HEAD 2>/dev/null) || revision="unknown"
  printf 'gitops_databases_apply_success %s\ngitops_databases_last_run_timestamp_seconds %s\n' "$apply_success" "$now"
  printf 'gitops_databases_last_success_timestamp_seconds %s\ngitops_databases_revision_info{revision="%s"} 1\n' "$last_success" "$revision"
}

# Runs when the script ends, whatever the reason. Written to a temporary file and moved, so the node_exporter never
# reads a half written file.
write_metrics() {
  local exit_status=$?
  if ! render_metrics "$exit_status" >"$METRICS_FILE.tmp" || ! mv "$METRICS_FILE.tmp" "$METRICS_FILE"; then
    log "Writing the metrics to $METRICS_FILE failed"
  fi
}

main() {
  parse_arguments "$@"
  if [[ -n $METRICS_FILE && $DRY_RUN == false ]]; then
    trap write_metrics EXIT
  fi
  require_commands sudo psql yq jq
  if [[ $PULL == true ]]; then
    pull_repository
  fi
  load_declared_state

  ensure_databases
  ensure_owner_privileges
  ensure_logins
  ensure_people
  if [[ $HAS_PEOPLE_SECTION == true ]]; then
    revoke_undeclared_access
  fi
  ensure_removed_logins
  ensure_removed_databases
  report_undeclared_logins
  report_undeclared_databases
}

main "$@"
