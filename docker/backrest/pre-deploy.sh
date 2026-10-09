#!/bin/bash
# =============================================================================
# pre-deploy.sh (backrest)
# Called by scripts/docker/deploy.sh before the project is started. Renders the Backrest
# configuration /root/docker/backrest/config/config.json from config.template.json: every
# ${NAME} is replaced by the value of NAME from default.env / override.env. The users (auth),
# the sync identity and modno of the file in use are kept, the rest comes from the template.
# Changes of repositories, plans and hooks therefore belong into config.template.json: what is
# changed in the Backrest UI is overwritten by the next deploy. Backrest is restarted afterwards.
#
#   bash docker/backrest/pre-deploy.sh [target file]
#
# With a target file only that file is written and nothing is restarted (to check the result).
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/root/docker/backrest/config/config.json"
CONTAINER="backrest"
TARGET="${1:-$CONFIG_FILE}"

REQUIRED_VARIABLES=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY RESTIC_PASSWORD_DOCKER RESTIC_PASSWORD_VAULT)
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

render_config() {
    local temporary
    temporary=$(mktemp "$TARGET.XXXXXX")
    chmod 600 "$temporary"
    jq --argjson live "$(live_config)" "$RENDER_PROGRAM" "$DIR/config.template.json" > "$temporary"
    mv "$temporary" "$TARGET"
    echo "[OK]    Rendered $TARGET"
}

restart_backrest() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        docker restart "$CONTAINER" >/dev/null
        echo "[OK]    $CONTAINER restarted, it reads the new configuration"
    fi
}

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq is required (apt install jq)" >&2; exit 1; }
export_variables
mkdir -p "$(dirname "$TARGET")"
render_config
if [[ "$TARGET" == "$CONFIG_FILE" ]]; then
    restart_backrest
fi
