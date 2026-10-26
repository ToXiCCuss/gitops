#!/usr/bin/env bash
# Makes the MariaDB database <target_database> a copy of <source_database>: all tables of the target are
# dropped and the dump of the source is imported. The target has to exist (db_create.sh), its roles and
# logins stay.
#
# Running it again leaves the target as a copy of the source as it is then, so the end state is the same.
# The tables of the target are deleted for good; use --dry-run first. Without arguments it copies
# fivem to fivem_dev, as the script always did.
#
# Usage: copy_db.sh [--dry-run] [source_database target_database]
#        --dry-run  only report what would be changed
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly DEFAULT_SOURCE_DATABASE="fivem"
readonly DEFAULT_TARGET_DATABASE="fivem_dev"
readonly MAX_NAME_LENGTH=64
readonly PROTECTED_DATABASES=(mysql sys information_schema performance_schema)

SOURCE_DB="$DEFAULT_SOURCE_DATABASE"
TARGET_DB="$DEFAULT_TARGET_DATABASE"
DUMP_FILE=""

usage() {
  log "Usage: $0 [--dry-run] [source_database target_database]"
  exit "$EXIT_USAGE"
}

parse_arguments() {
  local protected
  parse_options "$@"
  case ${#POSITIONAL[@]} in
  0) ;;
  2)
    SOURCE_DB=${POSITIONAL[0]}
    TARGET_DB=${POSITIONAL[1]}
    ;;
  *) usage ;;
  esac
  validate_name "source database name" "$SOURCE_DB" "$MAX_NAME_LENGTH"
  validate_name "target database name" "$TARGET_DB" "$MAX_NAME_LENGTH"
  [[ $SOURCE_DB != "$TARGET_DB" ]] || die "source and target are the same database"
  for protected in "${PROTECTED_DATABASES[@]}"; do
    [[ $TARGET_DB != "$protected" ]] || die "$TARGET_DB is a system database and cannot be overwritten"
  done
}

cleanup() {
  [[ -z $DUMP_FILE ]] || rm -f "$DUMP_FILE"
}

# The names are validated against NAME_PATTERN, so they can be put into the SQL directly
mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

require_database() {
  [[ -n "$(mariadb_admin -e "SELECT 1 FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$1'")" ]] ||
    die "database $1 does not exist"
}

# Only base tables: the views come back with the dump
drop_tables_of_target() {
  local statements
  statements=$(mariadb_admin -e "
    SELECT CONCAT('DROP TABLE IF EXISTS \`', TABLE_NAME, '\`;')
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '$TARGET_DB' AND TABLE_TYPE = 'BASE TABLE'")
  if [[ -z $statements ]]; then
    log "unchanged: $TARGET_DB has no tables"
  else
    mariadb_admin "$TARGET_DB" <<<"SET FOREIGN_KEY_CHECKS = 0;"$'\n'"$statements"
    log "dropped: $(wc -l <<<"$statements") tables of $TARGET_DB"
  fi
}

copy_data() {
  DUMP_FILE=$(mktemp)
  sudo mariadb-dump --single-transaction --quick --lock-tables=false --result-file="$DUMP_FILE" "$SOURCE_DB"
  drop_tables_of_target
  mariadb_admin "$TARGET_DB" <"$DUMP_FILE"
  log "updated: $TARGET_DB is a copy of $SOURCE_DB"
}

main() {
  trap cleanup EXIT
  parse_arguments "$@"
  require_commands sudo mariadb mariadb-dump mktemp
  require_database "$SOURCE_DB"
  require_database "$TARGET_DB"

  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] updated: $TARGET_DB would be a copy of $SOURCE_DB (not executed)"
  else
    copy_data
  fi
}

main "$@"
