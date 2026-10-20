#!/bin/bash
# =============================================================================
# pre-deploy.sh (rustfs)
# Called by scripts/docker/deploy.sh before the project is started. The image runs as the user
# 10001:10001, so the data and log directories on the host must belong to it, otherwise RustFS
# does not start.
# =============================================================================

set -euo pipefail

DATA_ROOT="/root/docker/rustfs"
RUNTIME_USER="10001:10001"

mkdir -p "$DATA_ROOT/data" "$DATA_ROOT/logs"
chown "$RUNTIME_USER" "$DATA_ROOT/data" "$DATA_ROOT/logs"
echo "[OK]    $DATA_ROOT/data and logs belong to $RUNTIME_USER"
