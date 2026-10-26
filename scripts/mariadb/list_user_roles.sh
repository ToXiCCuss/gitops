#!/usr/bin/env bash
# Lists the MariaDB logins with their roles and the databases (without the system databases). Read only.
#
# Usage: list_user_roles.sh
set -euo pipefail

# shellcheck source=../lib/database-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/database-common.sh"

readonly SEPARATOR="----------------------------------------------------------------------"
readonly SYSTEM_DATABASES="'information_schema', 'mysql', 'performance_schema', 'sys'"

usage() {
  log "Usage: $0"
  exit "$EXIT_USAGE"
}

mariadb_admin() {
  sudo mariadb --batch --skip-column-names "$@"
}

# MariaDB stores the role assignments in mysql.roles_mapping
print_logins() {
  echo "$SEPARATOR"
  echo "MariaDB logins and their roles (user, host, roles):"
  mariadb_admin -e "
    SELECT u.User, u.Host,
           (SELECT GROUP_CONCAT(rm.Role) FROM mysql.roles_mapping rm WHERE rm.User = u.User AND rm.Host = u.Host) AS roles
    FROM mysql.user u
    WHERE u.is_role = 'N'
    ORDER BY u.User, u.Host"
}

print_databases() {
  echo "$SEPARATOR"
  echo "Databases:"
  mariadb_admin -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ($SYSTEM_DATABASES) ORDER BY SCHEMA_NAME"
}

main() {
  (($# == 0)) || usage
  require_commands sudo mariadb

  print_logins
  print_databases
}

main "$@"
