#!/usr/bin/env bash
# =============================================================================
# pre-deploy.sh (netbird)
# Called by scripts/docker/deploy.sh before the project is started. Installs the files of this
# folder to /root/netbird and renders the templates with the keys from Vault.
#
# The rendered files stay on the host (mode 600), unlike the vault.env of the other projects: the
# server cannot read its secrets from the environment and /run is empty after a reboot. NetBird
# must also start without Vault, because Vault is reached through NetBird. For the
# same reason netbird_backup.sh, netbird_rollback.sh and netbird_restore.sh only work on /root/netbird.
#
# A deploy never changes an image: that goes through netbird_upgrade.sh and its rollback point.
# =============================================================================

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR
readonly NETBIRD_DIR="/root/netbird"
readonly VAULT_ENV_FILE="/run/gitops/netbird/vault.env"
readonly SECRET_NAMES=(NETBIRD_AUTH_SECRET NETBIRD_SESSION_COOKIE_ENCRYPTION_KEY NETBIRD_STORE_ENCRYPTION_KEY NB_PROXY_TOKEN NB_PROXY_CROWDSEC_API_KEY NETBIRD_DASHBOARD_BOUNCER_KEY)
readonly PLACEHOLDER_PREFIX="__VAULT_"
readonly PLAIN_FILE_MODE="644"
readonly SECRET_FILE_MODE="600"

work_dir=""
changed_files=()

log() { echo "$*" >&2; }
die() {
  log "[ERROR] $*"
  exit 1
}

cleanup() {
  [[ -z "$work_dir" ]] || rm -rf "$work_dir"
}

image_lines() {
  grep -E '^[[:space:]]+image:' "$1"
}

require_same_images() {
  local installed="$NETBIRD_DIR/docker-compose.yml"
  if [[ -f "$installed" && "$(image_lines "$installed")" != "$(image_lines "$SOURCE_DIR/docker-compose.yml")" ]]; then
    die "the image versions differ from $installed: run netbird_upgrade.sh, it makes a rollback point first"
  fi
}

encryption_key_of() {
  sed -n 's/^[[:space:]]*encryptionKey:[[:space:]]*//p' "$1"
}

# A different key makes the database unreadable, so a wrong value in Vault must never reach the file
require_same_encryption_key() {
  local rendered="$1" target="$NETBIRD_DIR/config.yaml"
  if [[ -f "$target" && "$(encryption_key_of "$target")" != "$(encryption_key_of "$rendered")" ]]; then
    die "NETBIRD_STORE_ENCRYPTION_KEY in Vault differs from $target, nothing was changed"
  fi
}

# render_template <template> <target>: the keys are replaced by bash itself, so no value appears in a process list
render_template() {
  local template="$1" target="$2" content name
  content=$(<"$template")
  for name in "${SECRET_NAMES[@]}"; do
    content=${content//"${PLACEHOLDER_PREFIX}${name}__"/"${!name}"}
  done
  [[ "$content" != *"$PLACEHOLDER_PREFIX"* ]] || die "$template has a placeholder that is not in SECRET_NAMES"
  printf '%s\n' "$content" >"$target"
}

# ensure_file <source> <target> <mode>: replaces the target only when the content differs, in one step
ensure_file() {
  local source_file="$1" target="$2" mode="$3"
  if [[ -f "$target" ]] && cmp -s "$source_file" "$target"; then
    chmod "$mode" "$target"
    log "[OK]    $target unchanged"
  else
    install -m "$mode" "$source_file" "$work_dir/next"
    mv "$work_dir/next" "$target"
    changed_files+=("$target")
    log "[OK]    $target updated"
  fi
}

# A file mounted on its own keeps showing the old content after the replace, until the container restarts.
# Compose does not see this change, it only recreates a container for the compose file and the env files
restart_if_changed() {
  local file="$1" container="$2"
  if [[ " ${changed_files[*]} " == *" $file "* ]] && docker inspect "$container" >/dev/null 2>&1; then
    docker restart "$container" >/dev/null
    log "[OK]    $container restarted"
  fi
}

main() {
  [[ -f "$VAULT_ENV_FILE" ]] || die "$VAULT_ENV_FILE is missing, deploy with scripts/docker/deploy.sh netbird"
  # shellcheck source=/dev/null
  source "$VAULT_ENV_FILE"

  mkdir -p "$NETBIRD_DIR/crowdsec/acquis.d"
  require_same_images

  work_dir=$(mktemp -d -p "$NETBIRD_DIR")
  trap cleanup EXIT
  render_template "$SOURCE_DIR/config.yaml.template" "$work_dir/config.yaml"
  render_template "$SOURCE_DIR/proxy.env.template" "$work_dir/proxy.env"
  render_template "$SOURCE_DIR/crowdsec.env.template" "$work_dir/crowdsec.env"
  render_template "$SOURCE_DIR/traefik-dynamic.yaml.template" "$work_dir/traefik-dynamic.yaml"
  require_same_encryption_key "$work_dir/config.yaml"

  ensure_file "$work_dir/config.yaml" "$NETBIRD_DIR/config.yaml" "$SECRET_FILE_MODE"
  ensure_file "$work_dir/proxy.env" "$NETBIRD_DIR/proxy.env" "$SECRET_FILE_MODE"
  ensure_file "$work_dir/crowdsec.env" "$NETBIRD_DIR/crowdsec.env" "$SECRET_FILE_MODE"
  ensure_file "$work_dir/traefik-dynamic.yaml" "$NETBIRD_DIR/traefik-dynamic.yaml" "$SECRET_FILE_MODE"
  ensure_file "$SOURCE_DIR/dashboard.env" "$NETBIRD_DIR/dashboard.env" "$PLAIN_FILE_MODE"
  ensure_file "$SOURCE_DIR/crowdsec-appsec.yaml" "$NETBIRD_DIR/crowdsec/acquis.d/appsec.yaml" "$PLAIN_FILE_MODE"
  ensure_file "$SOURCE_DIR/docker-compose.yml" "$NETBIRD_DIR/docker-compose.yml" "$PLAIN_FILE_MODE"

  restart_if_changed "$NETBIRD_DIR/config.yaml" netbird-server
  restart_if_changed "$NETBIRD_DIR/crowdsec/acquis.d/appsec.yaml" netbird-crowdsec
  restart_if_changed "$NETBIRD_DIR/traefik-dynamic.yaml" netbird-traefik
}

main "$@"
