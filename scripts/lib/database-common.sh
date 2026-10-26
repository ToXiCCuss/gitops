#!/usr/bin/env bash
# Sourced by the database scripts (scripts/postgresql, scripts/mariadb): logging, name checks, password
# generation and the Vault access for new passwords (vault-store-password.sh).

# shellcheck disable=SC2034 # used by the scripts that source this file
readonly EXIT_USAGE=2
readonly NAME_PATTERN='^[a-z][a-z0-9_]*$'
readonly PASSWORD_BYTES=15

DRY_RUN=false
POSITIONAL=()

log() { echo "$*" >&2; }
die() {
  log "Error: $*"
  exit 1
}

# parse_options "$@": --dry-run sets DRY_RUN, any other option calls usage() of the script, the rest is POSITIONAL
parse_options() {
  while (($# > 0)); do
    case $1 in
    --dry-run) DRY_RUN=true ;;
    -*) usage ;;
    *) POSITIONAL+=("$1") ;;
    esac
    shift
  done
}

# require_commands <command>...: stops at the start if a tool is missing
require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null || die "$command_name is missing"
  done
}

# validate_pattern <description> <value> <maximum length> <pattern>: the names reach the SQL, so only simple ones are allowed
validate_pattern() {
  [[ $2 =~ $4 && ${#2} -le $3 ]] ||
    die "the $1 must match $4 and have at most $3 characters"
}

# validate_name <description> <value> <maximum length>: the names of the scripts that create databases and logins
validate_name() {
  validate_pattern "$1" "$2" "$3" "$NAME_PATTERN"
}

generate_password() {
  openssl rand -hex "$PASSWORD_BYTES"
}

# shellcheck source=vault-store-password.sh
source "$(dirname "${BASH_SOURCE[0]}")/vault-store-password.sh"
