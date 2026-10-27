#!/usr/bin/env bash
# Takes access away from a personal login created by person_grant.sh.
#
# With a database the login's person role (<username>_role_person) leaves <db>_role_ro, _rw and _owner, so the
# login keeps its access to all other databases. Without a database the login and its person role do not exist
# afterwards.
#
# Idempotent: a missing login or missing access is reported as unchanged. Open connections of the login stay
# until they end (like in user_delete.sh). The password in Vault (databases/mariadb/<username>) is deleted first
# when the login goes, whether the login still exists or not, so a repeated run also cleans up an old leftover.
# The delete needs the current policy of scripts/vault/configure-vault-databases.ps1. The script only touches
# logins that have a person role, so it cannot drop an application login like shop_owner or root.
#
# Usage: person_revoke.sh [--dry-run] <username> [<database_name>]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

# "<username>_role_person" and "<db>_role_owner" have to fit into the 80 characters of a MariaDB user name
readonly MAX_NAME_LENGTH=52
readonly USER_HOST="%"

LOGIN=""
PERSON_ROLE=""
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
  PERSON_ROLE="${LOGIN}_role_person"

  DB_NAME=${POSITIONAL[1]:-}
  if [[ -n $DB_NAME ]]; then
    validate_name "database name" "$DB_NAME" "$MAX_NAME_LENGTH"
    ROLE_RO="${DB_NAME}_role_ro"
    ROLE_RW="${DB_NAME}_role_rw"
    ROLE_OWNER="${DB_NAME}_role_owner"
  fi
}

# The names are validated against NAME_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

# apply_sql <outcome> <resource>: runs the SQL from stdin, or only reports it with --dry-run
apply_sql() {
  local outcome=$1 resource=$2
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] $outcome: $resource (not executed)"
  else
    mariadb_admin
    log "$outcome: $resource"
  fi
}

login_exists() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$LOGIN' AND Host = '$USER_HOST' AND is_role = 'N'")" ]]
}

person_role_exists() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM mysql.user WHERE User = '$PERSON_ROLE' AND is_role = 'Y'")" ]]
}

# Checked before the Vault entry is deleted, so the entry of an application login is never touched
require_person_login_or_absent() {
  if login_exists; then
    person_role_exists ||
      die "$LOGIN exists but was not created by person_grant.sh (no role $PERSON_ROLE), so it is left alone"
  fi
}

ensure_access_revoked() {
  local current_roles=() current role statements=""
  current=$(mariadb_admin -e "SELECT GROUP_CONCAT(Role ORDER BY Role SEPARATOR ' ') FROM mysql.roles_mapping
    WHERE User = '$PERSON_ROLE' AND Role IN ('$ROLE_RO', '$ROLE_RW', '$ROLE_OWNER')")
  [[ $current != NULL ]] || current=""
  read -ra current_roles <<<"$current"

  if ((${#current_roles[@]} == 0)); then
    log "unchanged: $LOGIN has no access to $DB_NAME"
  else
    for role in "${current_roles[@]}"; do
      statements+="REVOKE '$role' FROM '$PERSON_ROLE';"$'\n'
    done
    apply_sql revoked "access of $LOGIN to $DB_NAME (was: $current)" <<<"$statements"
  fi
}

# The login goes before its person role: a run that stops in between leaves a role without a login, which the
# rerun drops, and the role stays the marker for as long as the login exists
ensure_login_absent() {
  require_vault_access
  ensure_vault_entry_absent "mariadb/$LOGIN"

  if login_exists; then
    apply_sql dropped "login $LOGIN" <<<"DROP USER '$LOGIN'@'$USER_HOST';"
  else
    log "unchanged: login $LOGIN@$USER_HOST does not exist"
  fi

  if person_role_exists; then
    apply_sql dropped "role $PERSON_ROLE" <<<"DROP ROLE '$PERSON_ROLE';"
  else
    log "unchanged: role $PERSON_ROLE does not exist"
  fi
}

main() {
  parse_arguments "$@"
  require_commands sudo mariadb
  require_person_login_or_absent

  if [[ -n $DB_NAME ]]; then
    ensure_access_revoked
  else
    ensure_login_absent
  fi
}

main "$@"
