#!/bin/sh
set -eu

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="$SCRIPT_DIR/override.env"

if ! docker network inspect internal_net >/dev/null 2>&1; then
    docker network create --internal --subnet 172.30.0.0/24 internal_net
    printf 'Network %s was created.\n' "internal_net"
fi

if ! docker network inspect external_net >/dev/null 2>&1; then
    docker network create --subnet 172.31.0.0/24 external_net
    printf 'Network %s was created.\n' "external_net"
fi

if [ ! -s "$ENV_FILE" ]; then
    command -v openssl >/dev/null 2>&1 || {
        printf '%s\n' 'Error: openssl is required to generate the secrets.' >&2
        exit 1
    }

    {
        printf 'ENCRYPTION_KEY=%s\n' "$(openssl rand -hex 32)"
        printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)"
    } > "$ENV_FILE"

    printf 'Secrets were generated once in %s.\n' "$ENV_FILE"
fi

docker compose up -d
