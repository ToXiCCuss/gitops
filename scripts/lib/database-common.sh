#!/usr/bin/env bash
# Sourced by the database scripts (scripts/postgresql, scripts/mariadb): logging, name checks, password
# generation and the Vault access for new passwords (vault-store-password.sh).

# shellcheck disable=SC2034 # used by the scripts that source this file
readonly EXIT_USAGE=2
readonly NAME_PATTERN='^[a-z][a-z0-9_]*$'
readonly PASSWORD_BYTES=15

log() { echo "$*" >&2; }
die() {
  log "Error: $*"
  exit 1
}

# require_commands <command>...: stops at the start if a tool is missing
require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || die "$command_name is missing"
  done
}

# validate_name <description> <value> <maximum length>: the names reach the SQL, so only simple ones are allowed
validate_name() {
  [[ $2 =~ $NAME_PATTERN && ${#2} -le $3 ]] ||
    die "the $1 must match $NAME_PATTERN and have at most $3 characters"
}

generate_password() {
  openssl rand -hex "$PASSWORD_BYTES"
}

# shellcheck source=vault-store-password.sh
source "$(dirname "${BASH_SOURCE[0]}")/vault-store-password.sh"
