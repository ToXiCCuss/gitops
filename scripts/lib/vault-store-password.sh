#!/usr/bin/env bash
# Sourced by the database scripts (scripts/postgresql, scripts/mariadb): stores the password of a new database
# user in Vault, so it is never printed or typed anywhere. The caller defines log() and die() (database-common.sh).
#
# The secret is databases/<dbms>/<username> (KV v2 engine "databases", keys username and password). The host
# logs in with the AppRole "dbadmin" (/etc/gitops/databases_role_id and _secret_id, mode 600), whose policy can
# only create and update secrets of this engine: it cannot read a password back or delete one.
# Setup: scripts/vault/configure-vault-databases.ps1, README section "Database passwords in Vault".

readonly VAULT_ADDR="${VAULT_ADDR:-https://vault.k8sdev.rjst.de}"
readonly VAULT_DATABASES_MOUNT="databases"
readonly VAULT_ROLE_ID_FILE="/etc/gitops/databases_role_id"
readonly VAULT_SECRET_ID_FILE="/etc/gitops/databases_secret_id"
readonly VAULT_TIMEOUT_SECONDS=15

# Checked before the first change, so a missing login stops the script while nothing was created yet
require_vault_access() {
  local tool file
  for tool in curl jq; do
    command -v "$tool" >/dev/null || die "$tool is missing"
  done
  for file in "$VAULT_ROLE_ID_FILE" "$VAULT_SECRET_ID_FILE"; do
    [[ -r $file ]] || die "$file is missing or not readable (README: Database passwords in Vault)"
  done
}

# vault_errors <response>: the error messages of a Vault answer, empty if it has none
vault_errors() {
  jq -r '(.errors // []) | join("; ")' <<<"$1" 2>/dev/null || true
}

# vault_login: prints a short-lived token. jq reads the files, so the secret_id is no argument
vault_login() {
  local response token
  response=$(jq -n --rawfile role_id "$VAULT_ROLE_ID_FILE" --rawfile secret_id "$VAULT_SECRET_ID_FILE" \
    '{role_id: ($role_id | rtrimstr("\n")), secret_id: ($secret_id | rtrimstr("\n"))}' |
    curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/auth/approle/login") ||
    die "Vault login: $VAULT_ADDR is not reachable"
  token=$(jq -r '.auth.client_token // empty' <<<"$response" 2>/dev/null)
  [[ -n $token ]] || die "Vault login refused: $(vault_errors "$response")"
  echo "$token"
}

# vault_store_password <dbms> <username> <password>
# The password reaches jq through the environment and curl through stdin, the token curl through a
# file descriptor, so none of them shows up in the process list
vault_store_password() {
  local dbms=$1 username=$2 password=$3 token response secret_path
  secret_path="$VAULT_DATABASES_MOUNT/$dbms/$username"
  token=$(vault_login)
  response=$(VAULT_PASSWORD=$password jq -n --arg username "$username" \
    '{data: {username: $username, password: env.VAULT_PASSWORD}}' |
    curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H @<(printf 'X-Vault-Token: %s\n' "$token") \
      -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/$VAULT_DATABASES_MOUNT/data/$dbms/$username") ||
    die "Vault: $VAULT_ADDR is not reachable"
  jq -e '.data.version' <<<"$response" >/dev/null 2>&1 ||
    die "Vault refused to store $secret_path: $(vault_errors "$response")"
  log "stored: password of $username in Vault ($secret_path)"
}
