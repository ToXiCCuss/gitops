# Shared by backup.sh and the host script scripts/docker/restore.sh (docker exec): which restic
# repositories exist and how to reach them. The S3 keys and the passwords come from the environment
# of the container (default.env / override.env). Sourced by /bin/sh, so POSIX only.

PCLOUD_REMOTE=pCloud
PCLOUD_ROOT=/Backups/s3

# repository_path <name>: bucket and path of the repository in the S3 (the offsite sync keeps the same path in pCloud)
repository_path() {
    case "$1" in
        docker)  echo "backups/docker" ;;
        vault)   echo "vault/raft" ;;
        netbird) echo "netbird/restic" ;;
        *)       return 1 ;;
    esac
}

repository_password() {
    case "$1" in
        docker)  echo "$RESTIC_PASSWORD_DOCKER" ;;
        vault)   echo "$RESTIC_PASSWORD_VAULT" ;;
        netbird) echo "$RESTIC_PASSWORD_NETBIRD" ;;
    esac
}

# select_repository <name> <s3|pcloud>: points restic at the repository, either the one on the local S3
# or its copy in pCloud (needs the rclone.conf mounted by the compose file)
select_repository() {
    repository_location=$(repository_path "$1") || { echo "Unknown repository: $1 (docker, vault or netbird)" >&2; return 1; }
    case "$2" in
        s3)     RESTIC_REPOSITORY="s3:$S3_ENDPOINT/$repository_location" ;;
        pcloud) RESTIC_REPOSITORY="rclone:$PCLOUD_REMOTE:$PCLOUD_ROOT/$repository_location" ;;
        *)      echo "Unknown source: $2 (s3 or pcloud)" >&2; return 1 ;;
    esac
    RESTIC_PASSWORD=$(repository_password "$1")
    export RESTIC_REPOSITORY RESTIC_PASSWORD
}
