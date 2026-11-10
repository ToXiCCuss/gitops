# Backup services

Setup details per service. Overview, schedule and restore: [backups.md](backups.md).

## restic-backup

One container with one shell script (`docker/restic-backup/backup.sh`, no UI). Once a night (03:00 UTC, after `vault-backup`, before the offsite sync) it does everything on the local S3, so backup, forget, prune and check never fight over the repository lock.

| Repository | Steps | Notes |
|---|---|---|
| `docker` (`backups/docker`) | `backup`, `forget`, `prune`, `check` | key files (below). `forget` keeps 7d/4w/6m over **all** snapshots (`--group-by ''`, so old Backrest snapshots age out). `prune` removes a pack when >10% unused; `check` reads 10%. `forget`/`prune` skipped when the backup failed |
| `databases` (`databases/restic`) | `backup-postgresql`, `backup-mariadb`, `forget`, `prune`, `check` | one SQL file per database, see [Database dumps](#database-dumps). `forget` keeps 14d/8w/6m per engine (tag). `backup-mariadb` only with `MARIADB_PASSWORD`. `forget`/`prune` skipped when no dump was backed up |
| `vault` (`vault/raft`), `netbird` (`netbird/restic`) | `check` | written/pruned by `vault-backup` and `netbird_backup.sh`; must exist, a missing one fails the step |

| Setting | Value |
|---|---|
| Paths | `/userdata/gitops` (checkout `/root/gitops`, no secrets), `/userdata/docker/offsite-sync/rclone/rclone.conf` (`KEY_FILES` in `backup.sh`) |
| Excludes | `/userdata/gitops/.git` (history is on GitHub) |
| Schedule | daily 03:00 UTC (`BACKUP_HOUR`, `BACKUP_MINUTE`) |
| Retention | daily 7, weekly 4, monthly 6 |

- Data directories of running databases are **not** copied (a live copy is inconsistent); databases go as dumps
- Secrets in Vault `docker/restic-backup` (S3 keys added from `docker/s3/restic-backup`); `default.env` lists all variables (run time, `KEEP_*`, `DATABASES_KEEP_*`, DB hosts and logins, `CHECK_READ_DATA_SUBSET`)
- Order on a new host: `setup-backup-host.sh`, secret in Vault (`vault kv put docker/restic-backup ...`), `deploy.sh restic-backup`
- The `docker` and `databases` repositories are initialised by the first run; `vault`/`netbird` already exist
- Checkout (`/root/gitops`) and `/root/docker` are mounted read-only; writable only `/restore`, `/dump`, restic cache
- `rclone.conf` of the offsite sync is mounted read-only, used only to restore from pCloud
- Run now: `docker exec restic-backup sh /backup.sh now` (log must end with `Run finished`). Everything incl. offsite sync: `sudo scripts/docker/backup-now.sh` (`--background` survives a dropped SSH session, follow with `tail -f`); NetBird server separately via `netbird_backup.sh`
- Failed steps are posted to Discord (optional) and the run exits with an error

### Move from Backrest (once)

1. `sudo scripts/docker/undeploy.sh --yes backrest` (data stays in `/root/docker/backrest`)
2. `git pull`, `sudo scripts/docker/setup-backup-host.sh` (creates `/root/docker/restic-backup`; S3 keys from Vault `docker/s3/restic-backup`)
3. `vault kv put docker/restic-backup ...` with the **same** `docker` password Backrest had
4. `sudo scripts/docker/deploy.sh restic-backup`, `docker exec restic-backup sh /backup.sh now`; check `Run finished` and `backup_last_success_timestamp_seconds{backup="restic-backup"}` in Prometheus
5. Dry run of forget on old snapshots: `docker exec restic-backup sh -c '. /common.sh && select_repository docker s3 && restic forget --dry-run --group-by "" --keep-daily 7 --keep-weekly 4 --keep-monthly 6'`
6. Once trusted: `rm -r /root/docker/backrest`; remove the reverse proxy service `backrest.proxy.rjst.de` in the NetBird dashboard

## Database dumps

`restic-backup` dumps the databases itself: it asks the server which exist, so a new database is in the next run. PostgreSQL 18 and MariaDB run on the host, the container reaches them as `host.docker.internal`.

| Engine | Dumped | Not dumped |
|---|---|---|
| PostgreSQL | `pg_dumpall --globals-only --no-role-passwords` + `pg_dump` of every database that accepts connections (not templates) | data directory, role passwords (in Vault) |
| MariaDB | `mariadb-dump --single-transaction --routines --events --triggers` of every database | `information_schema`, `performance_schema`, `mysql`, `sys` (users come from `scripts/mariadb`) |

- Dumps go to scratch folder `/dump` (`/root/docker/restic-backup/dump`, mode 700), are backed up as files, then the folder is emptied
- A failed dump is removed, others are still backed up, the step is reported failed (`restic_step_success{repository="databases"}`, `ResticStepFailed`). No pipe straight into restic: `/bin/sh` has no `pipefail`, a half-dead dump would look fine
- `pg_dump` must be version 18+ (Alpine `postgresql-client`)

### Setup

1. Create the backup logins once (`scripts/postgresql/backup_user_create.sh`, `scripts/mariadb/backup_user_create.sh`). PostgreSQL: `pg_read_all_data` + `CONNECT` on every database (the `ro` role of `user_create.sh` only sees `public` of one database and would miss e.g. schema `partman`). MariaDB: `SELECT`, `SHOW VIEW`, `TRIGGER`, `EVENT`, `LOCK TABLES`. Passwords go to Vault (`databases/postgresql/backup`, `databases/mariadb/backup`); existing login keeps its password, `reset` sets a new one
2. `CONNECT` is needed because `db_create.sh` revokes it from `PUBLIC`. `db_create.sh` grants it on new databases; for databases created otherwise re-run the script above (else the dump fails with `permission denied for database`)
3. Containers of the Docker network must reach PostgreSQL 5432, MariaDB 3306 and S3 9000 of the host. The Ansible `firewall` role allows `172.16.0.0/12`. Test from a container (`open` is right; timeout = blocked):

```bash
docker run --rm --add-host=host.docker.internal:host-gateway alpine nc -zv -w 5 host.docker.internal 5432
docker run --rm --add-host=host.docker.internal:host-gateway alpine nc -zv -w 5 host.docker.internal 3306
docker run --rm --add-host=host.docker.internal:host-gateway alpine nc -zv -w 5 host.docker.internal 9000
```

4. The host cannot read Vault passwords: copy them into the project secret (`vault kv patch` keeps other keys; new `RESTIC_PASSWORD_DATABASES`: `openssl rand -base64 24`, also into the password manager):

```bash
vault kv patch docker/restic-backup \
  POSTGRES_PASSWORD=$(vault kv get -field=password databases/postgresql/backup) \
  MARIADB_PASSWORD=$(vault kv get -field=password databases/mariadb/backup) \
  RESTIC_PASSWORD_DATABASES=<new password>
```

5. Identity `restic-backup` must write bucket `databases`: `sudo scripts/docker/setup-rustfs.sh`, then `sudo scripts/docker/setup-backup-host.sh` (folder `dump`) and `sudo scripts/docker/deploy.sh restic-backup` (recreated for the new mount)
6. Run once (`docker exec restic-backup sh /backup.sh now`), then restore a dump into a scratch database ([backups.md](backups.md#postgresql-and-mariadb))

Status: PostgreSQL tested (complete run + restore of `fw_chaos` into a scratch database). **Not yet verified:** the MariaDB dump (incl. client TLS `--skip-ssl` over the Docker bridge) and restoring a database that uses `pg_cron`/`pg_partman` (extensions needed on the target).

## Offsite sync

Nightly `rclone sync` of the S3 to pCloud (05:00 UTC, `SYNC_HOUR`) followed by `rclone check`. Deleted/overwritten files move to `Backups-deleted/<date>` for `RETENTION_DAYS`. **Only container holding pCloud credentials.**

- `rclone.conf` (pCloud remote) installed to `/root/docker/offsite-sync/rclone/rclone.conf` by `setup-backup-host.sh`
- S3 keys (read-only identity `offsite-sync`) from Vault `docker/s3/offsite-sync`; `DISCORD_WEBHOOK_URL` in Vault `docker/offsite-sync`
- `docker compose up -d` in the offsite-sync folder (or `deploy.sh offsite-sync`)

## RustFS

`docker/rustfs` is the local S3 of all backups (replaced SeaweedFS). Ports `9000` S3 API, `9001` console. RustFS is young (1.0.x): test restores now and then (also `--from pcloud`). **Nothing backs up its data** (`/root/docker/rustfs/data`, pCloud copy via offsite sync).

Buckets, users and policies come from `docker/rustfs/identities.json` (names and buckets, no keys); keys live in Vault `docker/s3/<name>`.

1. Keys: `setup-rustfs.sh` (step 7) generates missing keys itself and never changes an existing one (the loop in [vault.md](vault.md#secrets) does the same by hand). Read: `vault kv get -field=secret_key docker/s3/<name>`
2. Vault secret `docker/rustfs` (names in `docker/rustfs/vault.env.example`): `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` (root login, not `rustfsadmin`), `RUSTFS_IDENTITY_OPENID_CLIENT_SECRET` (= `RUSTFS_CLIENT_SECRET`)
3. Firewall rule for port 9000 from the Docker networks is in `ansible/group_vars/all/main.yml`
4. Keycloak: set `RUSTFS_CLIENT_SECRET` in Vault `docker/keycloak-config` (`openssl rand -base64 32`), `sudo scripts/docker/deploy.sh keycloak-config` creates client `rustfs` with roles `consoleAdmin`, `readwrite`, `readonly` (= RustFS policy names). The deploy stops with an undefined variable until the secret is set
5. Keycloak UI: give your user client role `consoleAdmin` of client `rustfs` (**Users > Role mapping**)
6. `sudo scripts/docker/deploy.sh rustfs` (`pre-deploy.sh` makes the data directories belong to user `10001`)
7. `sudo scripts/docker/setup-rustfs.sh` (RustFS running, AppRole files in place): keys for identities without them, buckets with the root key, then policy and user per identity via the admin API (`curl --aws-sigv4`, curl 7.75+). Last it tests every identity: lists its buckets, writes (`readwrite`) or must not write (`read`), neither write nor list outside its list
   An identity with `vaultCopy` in `identities.json` (`path`, `accessKey`, `secretKey`) gets its keys merged into that secret of the app in Vault at the end (e.g. `er-launcher-dev` into `dev/er-launcher-service`; the other keys of the secret stay, a missing secret is created with the two keys). The policy `docker-s3-keys` (`kubernetes/infra/kubectl/kube-vault-config.yaml`) allows exactly these paths: a new app needs its path there.
8. NetBird dashboard: reverse proxy service `s3-admin.proxy.rjst.de` to port `9001` of the Docker host, restricted to your peers

OIDC details:

- A container cannot use `https://auth.proxy.rjst.de` (the NetBird proxy only serves peers, `403` for a container). RustFS therefore uses Keycloak's published port: `RUSTFS_IDENTITY_OPENID_CONFIG_URL=http://host.docker.internal:8180/realms/rjst`, issuer checked against the public URL (`RUSTFS_IDENTITY_OPENID_ISSUER`)
- Needs `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` in `docker/keycloak/default.env`; deploy Keycloak first (`sudo scripts/docker/deploy.sh keycloak`, short restart)
- Check before first login (token endpoint must be `http://host.docker.internal:8180/...`, issuer public):

```bash
docker run --rm --add-host host.docker.internal:host-gateway curlimages/curl -s http://host.docker.internal:8180/realms/rjst/.well-known/openid-configuration
```

- If the call hangs, the firewall blocks the Docker network: `firewall_rules` entry like `ufw allow from 172.16.0.0/12 to any port 8180 proto tcp`
- Policies come from the claim `roles`; the root login (`RUSTFS_ACCESS_KEY`) stays as emergency login
- **Not verified:** whether `/rustfs/admin/v3/oidc/callback/default` is served on console port 9001 or API port 9000. On a 404 after Keycloak let the reverse proxy route `/rustfs/admin/` to 9000

## Pelican S3 backups

Pelican stores server backups in bucket `pelican` (identity `pelican`: Read/Write/List on this bucket only, created by `setup-rustfs.sh`). Field names may differ per version.

| Setting | Value |
|---|---|
| Driver | S3 in admin settings (Backups) |
| Endpoint | `http://100.67.0.1:9000` (NetBird address of `docker01`) |
| Bucket / region | `pelican` / any (e.g. `us-east-1`), path-style on |
| Keys | identity `pelican`: `vault kv get docker/s3/pelican` (no spaces/quotes; the browser password manager may fill wrong fields) |

- Why the IP: reachable from Panel and Wings (containers do not know `host.docker.internal` there nor `docker01.vpn.rjst.de`, host DNS is the NetBird resolver) and for browser downloads (presigned URLs; the browser must be in NetBird)
- The firewall rule for `172.16.0.0/12` covers destination `100.67.0.1`. Test (`open` is right):

```bash
docker run --rm --network wings0 alpine nc -zv -w 5 100.67.0.1 9000
docker run --rm --network pelicanpanel_default alpine nc -zv -w 5 100.67.0.1 9000
```

- Test a backup, the download and a restore on a test server; set backups per server in Pelican (every backup is a full archive, no deduplication)
- Backups are **plain `.tar.gz`, not encrypted**, restic is not involved; readable in the S3 and, after the sync, in pCloud (`Backups/s3/pelican/`, deleted archives stay 30 days in `Backups-deleted`). Intended
- Panel deliberately **not** backed up (SQLite in volume `pelican_panel_data`, only users/nodes/servers config); Wings config (`/etc/pelican`, node token) is recreated with the node; `/var/lib/pelican` is covered by the S3 backups
- Restore without the Panel: download the `.tar.gz` from S3 or pCloud and unpack into the server's data directory

## Vault backup

Daily 02:30 UTC (`BACKUP_HOUR`, `BACKUP_MINUTE`): fetches the Raft snapshot (`sys/storage/raft/snapshot`), writes it with restic to `vault/raft`, applies retention (`KEEP_*`, default 14d/8w/12m), reports failures to Discord. Runs in the host network (NetBird DNS to reach Vault, S3 on `127.0.0.1`).

- Token: periodic, renewed by every run, valid as long as the backup runs at least once per period (32 days); create as in [backups.md](backups.md#setup-order)
- Vault secret `docker/vault-backup`: `VAULT_TOKEN`, `RESTIC_PASSWORD`, optional `DISCORD_WEBHOOK_URL`; S3 keys of identity `vault` added from `docker/s3/vault`
- `docker compose up -d` in the vault-backup folder (or `deploy.sh vault-backup`)
- Restore: `scripts/vault/vault_restore.sh` ([backups.md](backups.md#vault))

## NetBird backup

The NetBird server (`docker01`, `/root/netbird`, `NETBIRD_DIR` in `/etc/netbird-backup.cred`) is backed up by the scripts in `scripts/netbird/`:

| Script | Purpose |
|---|---|
| `netbird_backup.sh` | stops NetBird briefly, copies config, `/var/lib/netbird` (SQLite store, keys), CrowdSec data, certificates, restarts (also on errors), restic to `netbird/restic` on the local S3, retention 8 weekly / 6 monthly. **No schedule**: runs before each upgrade (tag `pre-upgrade`) and by hand, so everything changed since is lost on restore. Failures to Discord. Over NetBird use `sudo netbird_backup.sh --background` (the run drops the SSH session; log `/var/log/netbird-backup.log`) |
| `netbird_restore.sh` | restore ([backups.md](backups.md#netbird)) |
| `netbird_upgrade.sh` | pre-upgrade backup + local rollback point; takes **all** versions (also CrowdSec, Traefik, replaced one at a time with `--no-deps`) from `docker/netbird/docker-compose.yml` in `/root/gitops` (`GITOPS_DIR`); shows the diff and copies the file to `/root/netbird` only after the backup |
| `netbird_rollback.sh` | back to the rollback point |
| `netbird_backup_setup.sh` | installs the scripts to `/usr/local/bin`, writes `/etc/netbird-backup.cred`, removes the old cron job |

- A PostgreSQL/MySQL store would need a separate backup

Set up on `docker01` (S3 on `127.0.0.1:9000`, no NetBird involved):

1. Identity and bucket `netbird` come from `identities.json` (`setup-rustfs.sh`); keys: `vault kv get docker/s3/netbird`
2. Discord webhook ([backups.md](backups.md#discord-alerts))
3. Setup (installs restic if missing, asks for S3 keys and restic password, initialises the repository):

```bash
cd scripts/netbird
sudo ./netbird_backup_setup.sh --discord-webhook <webhook url> --run
```

4. Restic password is in `/root/restic`: store it in the password manager
5. Test later with `sudo netbird_backup.sh`. Snapshots from before the move: `rclone:pCloud:/Backups/netbird` (set `RESTIC_REPOSITORY` for `netbird_restore.sh`)
