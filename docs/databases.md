# Databases

PostgreSQL 18 and MariaDB run on `docker01` (Ansible roles `postgresql`, `mariadb`). Scripts in `scripts/postgresql/` and `scripts/mariadb/`, run on the host with `sudo`.

## Script rules

- Idempotent: second run reports `unchanged`; aborted runs are finished by running again
- Everything that changes something has `--dry-run` (read-only `list_user_roles.sh`, `audit_list.sh` have none)
- Errors stop the script; no password is ever printed
- Needs `sudo`, DB client, `openssl`; password-storing scripts also `curl`, `jq`
- Names match `^[a-z][a-z0-9_]*$` (max 52 characters)

## Passwords in Vault

`db_create.sh` and `user_create.sh` store the password of a **new** user in Vault (`databases/<dbms>/<user>`, keys `username`, `password`); existing users keep theirs. Vault is written first: unreachable Vault stops the script before anything is created.

| Item | Detail |
|---|---|
| Policy / AppRole | `databases-write` (create/update `databases/data/*`, delete `databases/metadata/*`, **no read**) / `dbadmin` (token 5 min), in `infra/kubectl/kube-vault-config.yaml` |
| Host files | `/etc/gitops/databases_role_id`, `databases_secret_id` ([setup](vault.md#approle-logins-of-the-hosts)) |
| Read a password | `vault kv get -field=password databases/postgresql/keycloak_owner` |
| Rotate | `user_password.sh <login>` (or `<database> <username>`); old values stay as Vault versions |
| Legacy logins | not in Vault until their first `user_password.sh` run |
| CIDR binding | none (Vault sees a pod address) |

- Host can write/delete but not read: a leaked `secret_id` exposes no existing password, but can overwrite one. New `secret_id` cuts a leaked file off
- Backup login `backup`: after `reset` or a new password copy it into `docker/restic-backup` (`POSTGRES_PASSWORD`, `MARIADB_PASSWORD`) and redeploy `restic-backup`

### Script overview

| Script | Purpose |
|---|---|
| `db_create.sh <name>` | database with roles `owner`/`rw`/`ro`, owner login |
| `user_create.sh <db> <user> <role>` | application login `<db>_<user>` |
| `user_password.sh` | rotate password |
| `schema_create.sh <db> <schema>` | PostgreSQL schema with the privileges of the three roles |
| `copy_db.sh [source target]` | MariaDB: copy tables (default `fivem` to `fivem_dev`) |
| `list_user_roles.sh` | read only |
| `db_delete.sh`, `user_delete.sh`, `cleanup_db_user.sh` | **delete for good, `--dry-run` first**; refuse system DBs and MariaDB `root` |

- `db_delete.sh` finds logins by membership in the database's three roles, not by name (`shop` does not take `shop_dev`'s logins)
- Vault entry is deleted (all versions) **before** the login is dropped; if Vault refuses, the script stops with the login intact and can be repeated
- `user_delete.sh` also cleans up when the login is already gone

### Personal logins

`person_grant.sh <username> <database> <ro|rw>` / `person_revoke.sh <username> [<database>]` (PostgreSQL and MariaDB, same arguments, `--dry-run`).

- One login per person for all databases (no db prefix); run once per database (`ro` in `shop`, `rw` in `billing`)
- Without database: creates the login without access; a later run with a database adds it
- Changing the role type moves the login; `owner` is not possible (that is `<db>_owner`)
- Password goes to Vault (`databases/<dbms>/<username>`)
- Only touches logins it created (marker: role comment; MariaDB: role `<username>_role_person` as default role, since MariaDB enables one default role per connection)
- `person_revoke.sh <username>`: terminate sessions, delete Vault entry, drop login. Open MariaDB connections stay until they end

## Declared access

`databases/postgresql.yaml` declares databases, application logins and personal logins of `docker01`. `scripts/postgresql/apply_declared.sh` makes the server match it (via the scripts above). Needs `yq` and `jq` (installed by role `base`).

```yaml
databases:
  forgejo: {}
  developer_portal:
    ownerPrivileges: [create, temporary]   # database privileges of <db>_role_owner beyond db_create.sh
    logins:            # application logins <db>_<name>, role ro, rw or owner
      reader: ro
people:                # personal logins, ro or rw per database
  robert:
    forgejo: rw
```

| Topic | Behavior |
|---|---|
| First time | `sudo scripts/postgresql/export_declared.sh > databases/postgresql.yaml` prints the real state (read only); databases without the `db_create.sh` roles get a comment, check before applying; commit the file |
| Apply | the timer applies it after a merge to `master` ([Automatic apply](#automatic-apply)); by hand `sudo scripts/postgresql/apply_declared.sh --dry-run`, then without; each part reported as created/updated/unchanged |
| Removing access | automatic **only with the key `people:`** (unlisted personal logins dropped, unlisted databases revoked); without the key personal logins stay |
| `ownerPrivileges` | `create` (schemas) and/or `temporary` on the database; unlisted privileges are revoked. With `create`, default privileges give `ro`/`rw` `USAGE` on schemas the owner creates later (existing schemas stay closed) |
| Deleting | never automatic: undeclared databases/logins are only reported. `--prune` deletes undeclared databases (`db_delete.sh`), asks for each name and needs a terminal |
| Backstage | reads the file to show databases, never writes; rights change = pull request |

### Automatic apply

Timer `postgresql-apply.timer` (role `postgresql_apply`, `docker01`) runs `apply_declared.sh --pull --metrics-file ...` in `/root/gitops` hourly 08:30-20:30 (`postgresql_apply_calendar`), half an hour after `gitops-deploy.timer`. A merge to `master` that changes `databases/postgresql.yaml` is live on the server within the hour, **including every revoke** (`ownerPrivileges`, `people:`). **Rollback = `git revert` on `master`.** A failed `git pull` (e.g. DNS) is tried 4 times, 30 seconds apart, before the run counts as failed.

```bash
sudo ansible-playbook -i inventory.ini site.yml --tags postgresql_apply --check --diff   # in /root/gitops/ansible
sudo ansible-playbook -i inventory.ini site.yml --tags postgresql_apply
systemctl list-timers postgresql-apply.timer
journalctl -u postgresql-apply -n 100
sudo systemctl stop postgresql-apply.timer     # pause, e.g. while editing /root/gitops by hand
```

| Topic | Detail |
|---|---|
| Never automatic | `--prune`: databases are only deleted by hand at a terminal. Undeclared databases and logins are only reported in the journal |
| Preconditions | AppRole files `/etc/gitops/databases_role_id`, `databases_secret_id`; without them the run is skipped |
| Pull fails | local changes or a commit not on `master` stop the run (also `DockerDeployPullFailed`) |
| Metrics | `/var/lib/prometheus/node-exporter/postgresql-apply.prom`: `gitops_databases_apply_success`, `gitops_databases_last_run_timestamp_seconds`, `gitops_databases_last_success_timestamp_seconds`, `gitops_databases_revision_info{revision}` |
| Alerts | `kubernetes/monitoring/kubectl/alert-rules.yaml` (`postgresql-apply`): `DatabasesApplyFailed` after 30 min, `DatabasesApplyStale`, `DatabasesApplyNeverReported` after 2 h, via Alertmanager to Discord |
| First rollout | merge to `master`, `git pull` on the host, run the Ansible command; `--dry-run` of `apply_declared.sh` first must report only `unchanged` |
| Manual run | still allowed (`apply_declared.sh --dry-run`, then without); without `--metrics-file` it does not touch the metrics |
| Not covered | MariaDB (scripts only), schemas (`schema_create.sh`), audit setup, the `backup` login |

## MariaDB

Role sets `bind-address` and `event_scheduler = ON` (`/etc/mysql/mariadb.conf.d/60-gitops.cnf`). Port 3306 open for `172.16.0.0/12` only.

| Script | Purpose |
|---|---|
| `audit_setup.sh [--dry-run] <db> [months]` | `audit_log` (monthly partitions) + helper procedures + daily event that adds months and drops partitions older than retention (default 6). Re-run to change retention; data is kept |
| `audit_enable.sh [--dry-run] <db> <table> ...` | triggers log old/new values of INSERT/UPDATE/DELETE; re-run after a column change. Record id = primary key (`-` joined), `NULL` without. No-op UPDATEs not logged |
| `audit_disable.sh [--dry-run] <db> <table> ...` | removes triggers; logged rows stay until retention drops them |
| `audit_list.sh <db>` | audited tables, retention, partitions with row counts |
| `backup_user_create.sh [user] [reset]` | read-only backup login (`backup`, host `%`): `SELECT`, `SHOW VIEW`, `TRIGGER`, `EVENT`, `LOCK TABLES`; password to Vault `databases/mariadb/backup` |

- Audit log lives in the database (`db_delete.sh` takes it along), holds personal data in clear text; roles of `db_create.sh` can change it
- Costs one extra INSERT (all columns as JSON) per audited write: enable only where history is needed
- Partition `p_future` catches rows without a monthly partition; a stopped event scheduler only leaves partitions unmaintained
- **Monitoring:** role `mariadb_exporter` (`prometheus-mysqld-exporter`, port 9104, job `mysqld-exporter`, alert `MariaDBDown` on `mysql_up`). Login: user `prometheus@localhost` via socket (`unix_socket`, no password, `MAX_USER_CONNECTIONS 3`) with `PROCESS`, `BINLOG MONITOR`, `REPLICA MONITOR`, `SELECT` on `performance_schema.*`. Role creates the user. Collector `info_schema.processlist` enabled
- **Dashboard:** patched copy of 14057 in `kubernetes/monitoring/kubectl/dashboard-mariadb.yaml` (original filters on an undefined variable and reads a metric the exporter no longer has)
- **Backups:** `restic-backup` dumps with `mariadb-dump` once `MARIADB_PASSWORD` is in `docker/restic-backup`, see [backup-services.md](backup-services.md#database-dumps). `mariabackup` (physical) is for later

## PostgreSQL

Audit log as for MariaDB. Role `postgresql` preloads `pg_cron` (`shared_preload_libraries`, first run restarts PostgreSQL) and installs `pg_partman`.

| Script | Purpose |
|---|---|
| `audit_setup.sh [--dry-run] <db> [months]` | schema `audit` with `audit.audit_log` (monthly partitions by `pg_partman` + default partition), trigger function, daily `pg_cron` job 03:00 running `partman.run_maintenance()` (adds months, drops partitions past retention, default 6). Re-run to change retention |
| `audit_enable.sh [--dry-run] <db> <table> ...` | triggers write old/new row as JSON. Tables: `name` (schema `public`) or `schema.name`. Re-run after a primary key change |
| `audit_disable.sh [--dry-run] <db> <table> ...` | removes triggers |
| `audit_list.sh <db>` | audited tables, retention, `pg_cron` job, partitions with size and rows |
| `backup_user_create.sh [user] [reset]` | login `backup` with `pg_read_all_data` + `CONNECT` on all databases; password to Vault `databases/postgresql/backup` |
| `superuser_create.sh [--dry-run] <user> [reset]` | personal login with `SUPERUSER` (full rights on everything); password typed at the psql prompt, **not** stored in Vault; not part of `databases/postgresql.yaml`, `apply_declared.sh` does not touch it |

- Application roles of `db_create.sh` cannot read or change `audit.audit_log`; the trigger function runs as its owner. `postgres` and the backup role can read it
- The `pg_cron` job lives in the `pg_cron` database (`cron.database_name`, default `postgres`). After a restore from dump run `audit_setup.sh` again; `db_delete.sh` removes the job. Without `pg_cron` the default partition keeps logging, only maintenance stops
- After the Ansible run check `SHOW shared_preload_libraries;`
- PostgreSQL accepts connections from every address (`pg_hba.conf` `0.0.0.0/0`, `listen_addresses = '*'`): the firewall allows only the Docker network for 5432
- **Monitoring:** role `postgres_exporter` (port 9187, peer login as DB role `prometheus` with `pg_monitor`, extension `pg_stat_statements`, extra collectors in `postgres_exporter_collectors`), `pg_up` for alerts
