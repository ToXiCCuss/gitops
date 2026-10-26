#!/usr/bin/env bash
# Sourced by the database scripts (scripts/postgresql, scripts/mariadb): stores the password of a new database
# user in Vault, so it is never printed or typed anywhere. The caller defines log() and die() (database-common.sh).
#
# The secret is databases/<dbms>/<username> (KV v2 engine "databases", keys username and password). The host
# logs in with the AppRole "dbadmin" (/etc/gitops/databases_role_id and _secret_id, mode 600), whose policy can
# create, update and delete secrets of this engine: it cannot read a password back.
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

# vault_store_password <secret name> <username> <password>
# The secret name is the path below the engine, e.g. postgresql/shop_app or mongodb/shop/app.
# The password reaches jq through the environment and curl through stdin, the token curl through a
# file descriptor, so none of them shows up in the process list
vault_store_password() {
  local secret_name=$1 username=$2 password=$3 token response secret_path
  secret_path="$VAULT_DATABASES_MOUNT/$secret_name"
  token=$(vault_login)
  response=$(VAULT_PASSWORD=$password jq -n --arg username "$username" \
    '{data: {username: $username, password: env.VAULT_PASSWORD}}' |
    curl -sS -m "$VAULT_TIMEOUT_SECONDS" -H @<(printf 'X-Vault-Token: %s\n' "$token") \
      -H 'Content-Type: application/json' -d @- "$VAULT_ADDR/v1/$VAULT_DATABASES_MOUNT/data/$secret_name") ||
    die "Vault: $VAULT_ADDR is not reachable"
  jq -e '.data.version' <<<"$response" >/dev/null 2>&1 ||
    die "Vault refused to store $secret_path: $(vault_errors "$response")"
  log "stored: password of $username in Vault ($secret_path)"
}

# vault_delete_password <secret name>: removes the secret with all its versions (KV v2 metadata delete).
# Vault answers 204 for a secret that does not exist, so repeating the call is safe.
vault_delete_password() {
  local secret_name=$1 token response status secret_path
  secret_path="$VAULT_DATABASES_MOUNT/$secret_name"
  token=$(vault_login)
  response=$(curl -sS -m "$VAULT_TIMEOUT_SECONDS" -X DELETE -H @<(printf 'X-Vault-Token: %s\n' "$token") \
    -w '\n%{http_code}' "$VAULT_ADDR/v1/$VAULT_DATABASES_MOUNT/metadata/$secret_name") ||
    die "Vault: $VAULT_ADDR is not reachable"
  status=${response##*$'\n'}
  case $status in
  200 | 204 | 404) log "deleted: Vault entry $secret_path (an absent entry is fine)" ;;
  *) die "Vault refused to delete $secret_path (HTTP $status): $(vault_errors "${response%$'\n'*}"). The policy databases-write needs delete on $VAULT_DATABASES_MOUNT/metadata/*: run scripts/vault/configure-vault-databases.ps1" ;;
  esac
}

# ensure_vault_entry_absent <secret name>: vault_delete_password, or only a report with --dry-run (DRY_RUN is set by
# database-common.sh). The delete scripts call it before they drop the login, so a refused delete stops them while the
# login still exists and the run can simply be repeated.
ensure_vault_entry_absent() {
  if [[ $DRY_RUN == true ]]; then
    log "[dry-run] deleted: Vault entry $VAULT_DATABASES_MOUNT/$1 (not executed)"
  else
    vault_delete_password "$1"
  fi
}
