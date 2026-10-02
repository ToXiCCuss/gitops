#!/bin/bash
# =============================================================================
# setup-secrets.sh
# Creates and maintains ansible/group_vars/all/secrets.yml - the ansible-vault
# encrypted file that holds every secret the playbook needs (NetBird setup key,
# Harbor password, ...). The encrypted file IS committed to Git; the vault
# password lands in ansible/.vault_pass, which is gitignored.
#
#   ./setup-secrets.sh                    # values for THIS host (hostname -s)
#   ./setup-secrets.sh --scope all        # values shared by every host
#   ./setup-secrets.sh --scope docker01   # values for another host
#   ./setup-secrets.sh --view             # print the decrypted content
#   ./setup-secrets.sh --edit             # open it in $EDITOR (ansible-vault edit)
#   ./setup-secrets.sh --rekey            # rotate the vault password
#   ./setup-secrets.sh --password         # (re-)create .vault_pass only
#
# Values are stored per scope in a nested dict:
#
#   vault_secrets:
#     all:                  # fallback for every host
#       k3s_registries_harbor_password: ...
#     docker01:             # overrides "all" on that host
#       netbird_setup_key: ...
#
# Without --scope the script uses this machine's own short hostname, because the
# playbook runs locally on each host (inventory.ini: localhost/local). That is
# exactly the key ansible_hostname resolves to later.
#
# group_vars/all/main.yml resolves host -> all -> "" for each secret, so the
# roles keep using the plain variable names. host_vars/ cannot be used here:
# inventory.ini only knows "localhost", so host_vars/docker01.yml would never
# be loaded - ansible_hostname is a fact and holds the real hostname.
#
# To add a new secret: append its name to SECRET_NAMES and a matching one-line
# description to SECRET_HINTS below, then add the look-up to main.yml.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}> $*${RESET}"; }

# --- Secret registry ---------------------------------------------------------
SECRET_NAMES=(
    "netbird_setup_key"
    "k3s_registries_harbor_password"
)
SECRET_HINTS=(
    "NetBird setup key - NetBird dashboard > Setup Keys (roles/netbird)"
    "Harbor password for the k3s pull-through mirror (roles/k3s_registries)"
)

# --- Paths -------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$(cd "$SCRIPT_DIR/../../ansible" && pwd)"
SECRETS_FILE="$ANSIBLE_DIR/group_vars/all/secrets.yml"
MAIN_VARS_FILE="$ANSIBLE_DIR/group_vars/all/main.yml"
VAULT_PASS_FILE="$ANSIBLE_DIR/.vault_pass"

MODE="setup"
SCOPE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scope)    SCOPE="${2:-}"; shift 2 ;;
        --view)     MODE="view"; shift ;;
        --edit)     MODE="edit"; shift ;;
        --rekey)    MODE="rekey"; shift ;;
        --password) MODE="password"; shift ;;
        -h|--help)
            awk 'NR>2 && /^# ={10,}/{exit} NR>2{sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) error "Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

command -v ansible-vault >/dev/null 2>&1 || {
    error "ansible-vault is required (apt install ansible)"; exit 1; }
command -v python3 >/dev/null 2>&1 || {
    error "python3 is required (it ships with ansible)"; exit 1; }

valid_scope() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Reject a bad --scope before anything touches the vault.
if [[ -n "$SCOPE" ]] && ! valid_scope "$SCOPE"; then
    error "Invalid scope '$SCOPE' (allowed: letters, digits, . _ -)"
    exit 1
fi

# --- Temp files: anything unencrypted is shredded on exit --------------------
# Everything goes into one private 0700 directory. Tracking single files in an
# array does not work here: mktemp_secure is called via $(...), so the array
# append would happen in a subshell and be lost in the parent.
TMP_DIR="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/ansible-secrets.XXXXXX")"
cleanup() {
    [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] || return 0
    find "$TMP_DIR" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

mktemp_secure() { mktemp "$TMP_DIR/part.XXXXXX"; }

vault() { ansible-vault "$@" --vault-password-file "$VAULT_PASS_FILE"; }

# True when secrets.yml is absent or decrypts with the current password file.
vault_password_matches() {
    [[ -f "$SECRETS_FILE" ]] || return 0
    vault view "$SECRETS_FILE" >/dev/null 2>&1
}

write_vault_password() {
    (umask 077; printf '%s\n' "$1" > "$VAULT_PASS_FILE")
    chmod 600 "$VAULT_PASS_FILE"
}

# Writes the password to stdout; prompts go to stderr so they are not captured.
read_password_twice() {
    local pw1 pw2
    while true; do
        read -rsp "  Vault password: " pw1 >&2; echo >&2
        if [[ -z "$pw1" ]]; then
            echo -e "  ${RED}Must not be empty.${RESET}" >&2
            continue
        fi
        read -rsp "  Repeat:         " pw2 >&2; echo >&2
        if [[ "$pw1" != "$pw2" ]]; then
            echo -e "  ${RED}Passwords differ, try again.${RESET}" >&2
            continue
        fi
        printf '%s' "$pw1"
        return 0
    done
}

# --- Make sure .vault_pass exists and fits the committed secrets.yml ---------
ensure_vault_password() {
    if [[ -f "$VAULT_PASS_FILE" && "$MODE" != "password" ]]; then
        chmod 600 "$VAULT_PASS_FILE"
        if vault_password_matches; then
            success "Using the existing $VAULT_PASS_FILE"
            return 0
        fi
        warn "$VAULT_PASS_FILE does not decrypt the existing secrets.yml."
    fi

    local pw choice
    if [[ -f "$SECRETS_FILE" ]]; then
        # secrets.yml came from Git, so the password has to be typed in.
        step "Vault password for the committed secrets.yml"
        info "secrets.yml is already in the repository. Enter the vault password"
        info "it was encrypted with (password manager / another host)."
        while true; do
            read -rsp "  Vault password: " pw; echo
            [[ -n "$pw" ]] || continue
            write_vault_password "$pw"
            if vault_password_matches; then
                success "Password accepted, wrote $VAULT_PASS_FILE (chmod 600)"
                return 0
            fi
            error "Wrong password - secrets.yml cannot be decrypted with it."
        done
    fi

    # Fresh setup: no secrets.yml yet, so we get to pick the password.
    step "Creating a new vault password"
    echo "  [g] generate a random password (recommended)"
    echo "  [e] enter one yourself"
    read -rp "  Choice [g/e]: " choice
    if [[ "$choice" == "e" || "$choice" == "E" ]]; then
        pw="$(read_password_twice)"
        write_vault_password "$pw"
        success "Wrote $VAULT_PASS_FILE (chmod 600)"
        return 0
    fi

    pw="$(head -c 24 /dev/urandom | base64 | tr -d '\n')"
    write_vault_password "$pw"
    echo
    echo -e "${BOLD}${YELLOW}  +--------------------------------------------------------------+${RESET}"
    echo -e "${BOLD}${YELLOW}  | Vault password - store it in your password manager NOW!       |${RESET}"
    echo -e "${BOLD}${YELLOW}  +--------------------------------------------------------------+${RESET}"
    echo -e "${BOLD}    $pw${RESET}"
    echo
    warn "Without it the committed secrets.yml is unreadable on every other"
    warn "host - there is no recovery."
    read -rp "  Saved it? [Enter to continue] " _
}

# --- Scope selection ---------------------------------------------------------
# The scope defaults to this machine's own hostname, because the playbook runs
# locally on each host (inventory.ini: localhost ansible_connection=local).
# The domain part is stripped so it matches the ansible_hostname fact, which is
# the SHORT hostname and what group_vars/all/main.yml looks the values up by.
detect_hostname() {
    local h=""
    h="$(hostname -s 2>/dev/null)" || h=""
    [[ -n "$h" ]] || h="$(uname -n 2>/dev/null)" || h=""
    [[ -n "$h" ]] || h="${HOSTNAME:-}"
    printf '%s' "${h%%.*}"
}

# Hosts configured in every "*_hosts" list in group_vars/all/main.yml.
discover_hosts() {
    [[ -f "$MAIN_VARS_FILE" ]] || return 0
    python3 -c '
import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    sys.exit(0)
hosts = set()
for key, value in (data.items() if isinstance(data, dict) else []):
    if key.endswith("_hosts") and isinstance(value, list):
        hosts.update(h for h in value if isinstance(h, str) and h)
print("\n".join(sorted(hosts)))' "$MAIN_VARS_FILE" 2>/dev/null || true
}

choose_scope() {
    local origin
    if [[ -n "$SCOPE" ]]; then     # already validated during argument parsing
        origin="--scope"
    else
        SCOPE="$(detect_hostname)"
        origin="detected from the system hostname"
        if [[ -z "$SCOPE" ]]; then
            error "Could not determine the hostname - pass --scope <hostname> or --scope all."
            exit 1
        fi
        valid_scope "$SCOPE" || {
            error "Hostname '$SCOPE' is not usable as a scope - pass --scope <name> instead."
            exit 1; }
    fi

    step "Scope: $SCOPE"
    info "($origin)"

    # A host that is in no *_hosts list is usually a typo or a host that has not
    # been wired into the playbook yet - worth saying, but not an error.
    if [[ "$SCOPE" != "all" ]] && ! discover_hosts | grep -qxF "$SCOPE"; then
        warn "'$SCOPE' is not listed in any *_hosts list in group_vars/all/main.yml."
        warn "The values are stored anyway, but no role will run on this host yet."
    fi
}

# True when $1 (decrypted YAML) holds a non-empty value for $3 in scope $2.
has_value() {
    [[ -s "$1" ]] || return 1
    python3 -c '
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
scopes = data.get("vault_secrets") or {}
entry = scopes.get(sys.argv[2]) or {}
value = entry.get(sys.argv[3], "") if isinstance(entry, dict) else ""
sys.exit(0 if str(value) != "" else 1)' "$1" "$2" "$3"
}

# --- Ask for every secret; plain Enter keeps the current value ---------------
collect_secrets() {
    local current_file="$1" scope="$2"

    step "Secret values for scope '$scope'"
    info "Enter = keep the current value, '-' = remove the entry."
    if [[ "$scope" != "all" ]]; then
        info "A removed entry falls back to the value from scope 'all'."
    fi
    echo

    local i name hint state val changed=1
    for i in "${!SECRET_NAMES[@]}"; do
        name="${SECRET_NAMES[$i]}"
        hint="${SECRET_HINTS[$i]}"

        if has_value "$current_file" "$scope" "$name"; then
            state="${GREEN}set${RESET}"
        elif has_value "$current_file" "all" "$name"; then
            state="${BLUE}inherited from 'all'${RESET}"
        else
            state="${YELLOW}not set${RESET}"
        fi

        echo -e "  ${BOLD}$name${RESET}  [$state]"
        echo -e "    ${CYAN}$hint${RESET}"
        read -rsp "    Value: " val; echo
        echo

        if [[ "$val" == "-" ]]; then
            export "SEC_${name}="
            changed=0
        elif [[ -n "$val" ]]; then
            export "SEC_${name}=$val"
            changed=0
        fi
    done

    return $changed
}

# --- Merge current + new values, then re-encrypt -----------------------------
write_secrets() {
    local current_file="$1" merged_file="$2" scope="$3"

    CURRENT_FILE="$current_file" MERGED_FILE="$merged_file" SCOPE="$scope" \
    SECRET_LIST="$(printf '%s\n' "${SECRET_NAMES[@]}")" \
    python3 -c '
import os, yaml

current = os.environ["CURRENT_FILE"]
merged = os.environ["MERGED_FILE"]
scope = os.environ["SCOPE"]
names = [n for n in os.environ["SECRET_LIST"].splitlines() if n]

# Start from what is already in the vault so hand-edited or extra keys survive.
data = {}
if os.path.isfile(current) and os.path.getsize(current) > 0:
    data = yaml.safe_load(open(current, encoding="utf-8")) or {}
if not isinstance(data, dict):
    raise SystemExit("secrets.yml does not hold a YAML mapping - fix it with --edit")

scopes = data.get("vault_secrets")
if scopes is None:
    scopes = {}
if not isinstance(scopes, dict):
    raise SystemExit("vault_secrets is not a mapping - fix it with --edit")
data["vault_secrets"] = scopes

entry = scopes.get(scope)
if not isinstance(entry, dict):
    entry = {}
scopes[scope] = entry

for name in names:
    value = os.environ.get("SEC_" + name)
    if value is None:
        continue          # untouched
    if value == "":
        entry.pop(name, None)   # cleared -> falls back to scope "all"
    else:
        entry[name] = value

# Drop scopes that ran empty, but always keep vault_secrets itself so the
# look-ups in main.yml never hit an undefined variable.
for key in [k for k, v in scopes.items() if not v]:
    del scopes[key]

header = (
    "---\n"
    "# Secrets for the Ansible playbook - ansible-vault encrypted, committed to Git.\n"
    "# Structure: vault_secrets[<hostname>|all][<secret name>]\n"
    "# Resolved per host in group_vars/all/main.yml (host -> all -> \"\").\n"
    "# Do not edit the encrypted file by hand; use:\n"
    "#   scripts/ansible/setup-secrets.sh                  (change values)\n"
    "#   scripts/ansible/setup-secrets.sh --scope <host>   (one host)\n"
    "#   scripts/ansible/setup-secrets.sh --edit           (raw edit)\n"
)
with open(merged, "w", encoding="utf-8") as fh:
    fh.write(header)
    yaml.safe_dump(data, fh, default_flow_style=False, allow_unicode=True, sort_keys=True)
'

    ansible-vault encrypt \
        --vault-password-file "$VAULT_PASS_FILE" \
        --output "$SECRETS_FILE" \
        "$merged_file" >/dev/null
    chmod 600 "$SECRETS_FILE"
}

require_secrets_file() {
    [[ -f "$SECRETS_FILE" ]] || {
        error "$SECRETS_FILE does not exist yet - run the script without arguments first."
        exit 1; }
}

# --- Modes that only wrap ansible-vault -------------------------------------
case "$MODE" in
    view)
        require_secrets_file
        ensure_vault_password
        step "Decrypted content of secrets.yml"
        vault view "$SECRETS_FILE"
        exit 0 ;;
    edit)
        require_secrets_file
        ensure_vault_password
        vault edit "$SECRETS_FILE"
        success "secrets.yml re-encrypted - remember to commit it."
        exit 0 ;;
    rekey)
        require_secrets_file
        ensure_vault_password
        step "Rotating the vault password"
        NEW_PASS_FILE="$(mktemp_secure)"
        NEW_PW="$(read_password_twice)"
        (umask 077; printf '%s\n' "$NEW_PW" > "$NEW_PASS_FILE")
        ansible-vault rekey \
            --vault-password-file "$VAULT_PASS_FILE" \
            --new-vault-password-file "$NEW_PASS_FILE" \
            "$SECRETS_FILE" >/dev/null
        write_vault_password "$NEW_PW"
        success "secrets.yml re-encrypted, $VAULT_PASS_FILE updated."
        warn "Update the password in your password manager and on every other host."
        warn "Commit the re-encrypted secrets.yml."
        exit 0 ;;
    password)
        ensure_vault_password
        exit 0 ;;
esac

# --- Normal setup / update run ----------------------------------------------
step "Ansible secrets - $SECRETS_FILE"
mkdir -p "$(dirname "$SECRETS_FILE")"
ensure_vault_password

CURRENT_FILE="$(mktemp_secure)"
if [[ -f "$SECRETS_FILE" ]]; then
    vault view "$SECRETS_FILE" > "$CURRENT_FILE"
    info "Existing secrets.yml read - values you skip stay untouched."
fi

choose_scope

if collect_secrets "$CURRENT_FILE" "$SCOPE"; then
    MERGED_FILE="$(mktemp_secure)"
    write_secrets "$CURRENT_FILE" "$MERGED_FILE" "$SCOPE"
    vault view "$SECRETS_FILE" >/dev/null || {
        error "Verification failed - secrets.yml is not decryptable!"; exit 1; }
    success "$SECRETS_FILE written and verified (scope '$SCOPE', ansible-vault AES256)"
elif [[ -f "$SECRETS_FILE" ]]; then
    info "No value changed - secrets.yml left as it is."
else
    warn "No value was entered, so $SECRETS_FILE was NOT created."
    warn "Enter at least one value - a plain Enter only keeps an existing one,"
    warn "and there is nothing to keep yet."
fi

# --- Summary ----------------------------------------------------------------
step "Next steps"
if [[ -f "$SECRETS_FILE" ]]; then
    echo "  Run the playbook (ansible.cfg already points at .vault_pass):"
    echo
    echo "      cd $ANSIBLE_DIR"
    echo "      ansible-playbook site.yml --check --diff"
    echo "      ansible-playbook site.yml"
    echo
    echo "  Commit the ENCRYPTED file:"
    echo
    echo "      git add ansible/group_vars/all/secrets.yml"
    echo "      git commit -m \"Update Ansible vault secrets\""
    echo
else
    echo "  secrets.yml does not exist yet - run the script again and enter a value."
    echo
fi
echo "  Values shared by all hosts:  $0 --scope all"
echo "  Values for another host:     $0 --scope <hostname>"
echo "  Show everything:             $0 --view"
echo
echo "  .vault_pass is gitignored and must never be committed. On another host"
echo "  set it up with: scripts/ansible/setup-secrets.sh --password"
echo
