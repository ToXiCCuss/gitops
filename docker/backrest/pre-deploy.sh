#!/bin/bash
# =============================================================================
# pre-deploy.sh (backrest)
# Called by scripts/docker/deploy.sh before the project is started. Renders the Backrest
# configuration /root/docker/backrest/config/config.json from config.template.json: every
# ${NAME} is replaced by the value of NAME from default.env / override.env. The users (auth),
# the sync identity and modno of the file in use are kept, the rest comes from the template.
# Changes of repositories, plans and hooks therefore belong into config.template.json: what is
# changed in the Backrest UI is overwritten by the next deploy.
#
# Backrest is restarted afterwards. If it does not answer on its port with the new file, the
# previous config.json (saved as config.json.before-deploy) is put back, Backrest is restarted
# again and the script fails, so that deploy.sh reports it.
#
#   bash docker/backrest/pre-deploy.sh [target file]
#
# With a target file only that file is written and nothing is restarted (to check the result).
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/root/docker/backrest/config/config.json"
BACKUP_FILE="$CONFIG_FILE.before-deploy"
CONTAINER="backrest"
HEALTH_URL="http://127.0.0.1:9898"
HEALTH_ATTEMPTS=15
HEALTH_WAIT_SECONDS=2
TARGET="${1:-$CONFIG_FILE}"

REQUIRED_VARIABLES=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD_DOCKER RESTIC_PASSWORD_VAULT RESTIC_PASSWORD_NETBIRD)
OPTIONAL_VARIABLES=(DISCORD_WEBHOOK_URL)

# Without a webhook the hooks are left out, Backrest would refuse an empty URL
RENDER_PROGRAM='
def withoutHooks: walk(if type == "object" then del(.hooks) else . end);
def substituted: walk(if type == "string" then gsub("\\$\\{(?<name>[A-Z0-9_]+)\\}"; $ENV[.name]) else . end);
(if ($ENV.DISCORD_WEBHOOK_URL // "") == "" then withoutHooks else . end)
| substituted
| .modno = ($live.modno // 1)
| (if $live.auth then .auth = $live.auth else . end)
| (if $live.sync then .sync = $live.sync else . end)
'

# env_value <name>: the last assignment in override.env, else the one in default.env (no quotes)
env_value() {
    local file value=""
    for file in "$DIR/default.env" "$DIR/override.env"; do
        if [[ -f "$file" ]] && grep -q "^$1=" "$file"; then
            value=$(grep "^$1=" "$file" | tail -n 1 | cut -d= -f2-)
        fi
    done
    printf '%s' "$value"
}

export_variables() {
    local name
    for name in "${REQUIRED_VARIABLES[@]}" "${OPTIONAL_VARIABLES[@]}"; do
        export "$name=$(env_value "$name")"
    done
    for name in "${REQUIRED_VARIABLES[@]}"; do
        [[ -n "${!name}" ]] || { echo "[ERROR] $name is empty in override.env" >&2; exit 1; }
    done
}

# The file in use, or an empty object on the first deploy
live_config() {
    if [[ -f "$CONFIG_FILE" ]]; then cat "$CONFIG_FILE"; else echo '{}'; fi
}

# Saves the file in use so that a failed start can go back to it
backup_live_config() {
    if [[ "$TARGET" == "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        cp -p "$CONFIG_FILE" "$BACKUP_FILE"
    fi
}

render_config() {
    local temporary
    temporary=$(mktemp "$TARGET.XXXXXX")
    chmod 600 "$temporary"
    if jq --argjson live "$(live_config)" "$RENDER_PROGRAM" "$DIR/config.template.json" > "$temporary"; then
        mv "$temporary" "$TARGET"
        echo "[OK]    Rendered $TARGET"
    else
        rm -f "$temporary"
        echo "[ERROR] jq could not render config.template.json, $TARGET is unchanged" >&2
        exit 1
    fi
}

# True as soon as Backrest answers on its port (any HTTP status), false after the last attempt
is_backrest_up() {
    local attempt code up=1
    for attempt in $(seq 1 "$HEALTH_ATTEMPTS"); do
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$HEALTH_URL" || true)
        if [[ -n "$code" && "$code" != "000" ]]; then
            up=0
            break
        fi
        sleep "$HEALTH_WAIT_SECONDS"
    done
    return "$up"
}

show_backrest_log() {
    docker logs --tail 15 "$CONTAINER" 2>&1 | sed -E 's#(https://discord(app)?\.com/api/webhooks/)[^ "]*#\1<masked>#g'
}

# Puts the previous file back, tells what happened and ends the script with an error
roll_back_and_fail() {
    if [[ -f "$BACKUP_FILE" ]]; then
        cp -p "$BACKUP_FILE" "$CONFIG_FILE"
        docker restart "$CONTAINER" >/dev/null
        if is_backrest_up; then
            echo "[WARN]  The previous configuration is back, $CONTAINER runs again. The new one was not applied" >&2
        else
            echo "[ERROR] $CONTAINER does not answer with the previous configuration either: docker logs $CONTAINER" >&2
        fi
    else
        echo "[ERROR] There is no previous configuration to go back to" >&2
    fi
    exit 1
}

restart_backrest() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        docker restart "$CONTAINER" >/dev/null
        if is_backrest_up; then
            echo "[OK]    $CONTAINER restarted, it reads the new configuration"
        else
            echo "[ERROR] $CONTAINER does not answer with the new configuration:" >&2
            show_backrest_log >&2
            roll_back_and_fail
        fi
    fi
}

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required (apt install jq)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ERROR] curl is required (apt install curl)" >&2; exit 1; }
export_variables
mkdir -p "$(dirname "$TARGET")"
backup_live_config
render_config
if [[ "$TARGET" == "$CONFIG_FILE" ]]; then
    restart_backrest
fi
