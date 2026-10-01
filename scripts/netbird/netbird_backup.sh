#!/bin/bash
# =============================================================================
# netbird_backup.sh
# Backs up a self-hosted NetBird (docker compose) installation to restic,
# following https://docs.netbird.io/selfhosted/maintenance/backup
#
# What is backed up:
#   - config files from the install dir (docker-compose.yml, config.yaml,
#     dashboard.env, proxy.env, traefik-dynamic.yaml, crowdsec/, ...)
#   - /var/lib/netbird from the management container (SQLite store + keys)
#   - CrowdSec data, proxy certs and Traefik Let's Encrypt data if present
#
# NetBird is stopped while the data is copied (consistent SQLite copy) and is
# always started again, even if the backup fails.
#
# NOTE: with a PostgreSQL/MySQL store the database must be backed up separately.
#
# Optional overrides in /etc/netbird-backup.cred:
#   NETBIRD_DIR, RESTIC_REPOSITORY,
#   RESTIC_PASSWORD_FILE, BACKUP_DIR, RESTIC_KEEP_DAILY/WEEKLY/MONTHLY,
#   PUSH_URL (Uptime Kuma push monitor, the only notification), AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   (keys of the S3 identity "netbird")
#
# Environment (used by netbird_upgrade.sh):
#   KEEP_STAGING_DIR  move the staged backup there instead of deleting it
#   EXTRA_TAG         additional restic tag for this snapshot (e.g. pre-upgrade)
# =============================================================================

CONFIG_FILE="/etc/netbird-backup.cred"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi


format_duration() {
    local seconds=$1
    local h=$((seconds / 3600))
    local m=$((seconds % 3600 / 60))
    local s=$((seconds % 60))

    if [ $h -gt 0 ]; then
        echo "${h}h ${m}m ${s}s"
    elif [ $m -gt 0 ]; then
        echo "${m}m ${s}s"
    else
        echo "${s}s"
    fi
}

NETBIRD_DIR="${NETBIRD_DIR:-/opt/netbird}"

# Local SeaweedFS S3 of this Docker host (offsite sync copies it to pCloud)
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-s3:http://127.0.0.1:8333/netbird/restic}"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/restic}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-7}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-4}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/netbird}"
STAGING_DIR="$BACKUP_DIR/latest"

CONFIG_FILES=(docker-compose.yml config.yaml dashboard.env proxy.env traefik-dynamic.yaml
              management.json turnserver.conf relay.env zitadel.env .env)

# Report to the Uptime Kuma push monitor (optional). The URL may contain the query Kuma shows, it is cut off
push_status() {
    [ -n "${PUSH_URL:-}" ] && curl -fsS -m 10 "${PUSH_URL%%\?*}?status=$1&msg=$2" >/dev/null || true
}

fail() {
    echo "[ERROR] $1"
    push_status down backup-failed
    exit 1
}

# --- Preflight ---------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root"
    exit 1
fi

[ -f "$NETBIRD_DIR/docker-compose.yml" ] || fail "No docker-compose.yml in $NETBIRD_DIR"
cd "$NETBIRD_DIR" || fail "Cannot cd into $NETBIRD_DIR"

SERVICES=$(docker compose config --services 2>/dev/null) || fail "docker compose config failed in $NETBIRD_DIR"
has_service() { grep -qx "$1" <<< "$SERVICES"; }

# Combined server image is "netbird-server", older setups use "management"
if has_service netbird-server; then
    MGMT_SERVICE="netbird-server"
elif has_service management; then
    MGMT_SERVICE="management"
else
    fail "No netbird-server/management service found in docker-compose.yml"
fi

START_TIME=$(date +%s)
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
chmod 700 "$BACKUP_DIR"

# --- Stop NetBird (always restart on exit) -----------------------------------
echo "[INFO] Stopping NetBird services..."
docker compose stop || fail "docker compose stop failed"

restart_services() {
    echo "[INFO] Starting NetBird services..."
    if ! docker compose start; then
        echo "[ERROR] docker compose start failed"
    fi
}
trap restart_services EXIT

# --- Config files ------------------------------------------------------------
echo "[INFO] Copying configuration files..."
for f in "${CONFIG_FILES[@]}"; do
    if [ -f "$f" ]; then
        cp -a "$f" "$STAGING_DIR/" || fail "Failed to copy $f"
    fi
done
if [ -d crowdsec ]; then
    cp -a crowdsec "$STAGING_DIR/crowdsec" || fail "Failed to copy crowdsec config"
fi

# --- Data volumes ------------------------------------------------------------
echo "[INFO] Copying NetBird data from $MGMT_SERVICE..."
docker compose cp -a "$MGMT_SERVICE:/var/lib/netbird/" "$STAGING_DIR/" \
    || fail "Failed to copy /var/lib/netbird from $MGMT_SERVICE"
echo "$MGMT_SERVICE" > "$STAGING_DIR/.mgmt_service"

if has_service crowdsec; then
    echo "[INFO] Copying CrowdSec data..."
    docker compose cp -a crowdsec:/var/lib/crowdsec/data/ "$STAGING_DIR/crowdsec_db/" \
        || fail "Failed to copy CrowdSec data"
fi

# --- Certificates (optional) -------------------------------------------------
if has_service proxy; then
    echo "[INFO] Copying proxy certificates..."
    docker compose cp -a proxy:/certs/ "$STAGING_DIR/proxy_certs/" \
        || echo "[WARN] Could not copy proxy certificates, continuing."
fi
if has_service traefik; then
    echo "[INFO] Copying Traefik Let's Encrypt data..."
    docker compose cp -a traefik:/letsencrypt/ "$STAGING_DIR/traefik_letsencrypt/" \
        || echo "[WARN] Could not copy Traefik Let's Encrypt data, continuing."
fi

# --- Start NetBird again -----------------------------------------------------
trap - EXIT
restart_services

echo "[INFO] Backup staged in: $STAGING_DIR"

# --- Restic ------------------------------------------------------------------
echo "[INFO] Starting Restic backup..."
if command -v restic >/dev/null 2>&1; then
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        backup --tag netbird ${EXTRA_TAG:+--tag "$EXTRA_TAG"} "$STAGING_DIR" \
        || fail "Restic backup failed"

    echo "[INFO] Applying retention policy..."
    restic -r "$RESTIC_REPOSITORY" \
        --password-file "$RESTIC_PASSWORD_FILE" \
        forget --tag netbird --prune \
        --keep-daily "$RESTIC_KEEP_DAILY" \
        --keep-weekly "$RESTIC_KEEP_WEEKLY" \
        --keep-monthly "$RESTIC_KEEP_MONTHLY" \
        || echo "[WARN] Restic forget/prune failed, continuing."
else
    fail "Restic not found - backup only exists locally in $STAGING_DIR"
fi

if [ -n "$KEEP_STAGING_DIR" ]; then
    mkdir -p "$(dirname "$KEEP_STAGING_DIR")"
    mv "$STAGING_DIR" "$KEEP_STAGING_DIR" || fail "Failed to move staging data to $KEEP_STAGING_DIR"
    echo "[INFO] Local staging data kept in: $KEEP_STAGING_DIR"
else
    rm -rf "$STAGING_DIR"
    echo "[INFO] Local staging data deleted."
fi

END_TIME=$(date +%s)
DURATION_SECONDS=$((END_TIME - START_TIME))
DURATION=$(format_duration $DURATION_SECONDS)

echo "[INFO] NetBird backup completed successfully in $DURATION."
push_status up OK
