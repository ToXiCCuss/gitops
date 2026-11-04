# Ansible

Host setup for `docker01` (Docker host) and `k8sdev01` (k3s node). Run everything from `ansible/`.

## Run

| Step | Command |
|---|---|
| Install (Debian) | `sudo apt update && sudo apt install -y ansible git && git clone https://github.com/ToXiCCuss/gitops.git` |
| Collections | `cd gitops/ansible && ansible-galaxy collection install -r requirements.yml` |
| Dry run | `ansible-playbook -i inventory.ini site.yml --check --diff` |
| Apply | `ansible-playbook -i inventory.ini site.yml` |
| One role | add `--tags <firewall\|k3s\|node_exporter\|gitops_deploy>` |

- Playbook runs **locally on each host** (`/root/gitops/ansible`), the checkout comes via `git pull`
- Hosts cannot push to Git; edit on the workstation
- No secrets in Ansible (no ansible-vault)

## Roles and hosts

Host lists are in `group_vars/all/main.yml`; per-host settings under `host_config.<host>`.

| Role | Hosts | Purpose |
|---|---|---|
| `base` | all | timezone, inotify limits, unattended-upgrades (no auto reboot), SSH key-only for root |
| `netbird` | `docker01`, `k8sdev01` | install client; join is manual |
| `firewall` | `docker01`, `k8sdev01` | UFW from `host_config.<host>.firewall_rules` |
| `node_exporter` | `docker01`, `k8sdev01` | exporter + textfile collector + update status |
| `docker` | `docker01` | Docker CE, `daemon.json`, restart of socket containers |
| `gitops_deploy` | `docker01` | timer that runs `deploy.sh` |
| `postgresql`, `postgres_exporter` | `docker01` | PostgreSQL 18 (`pg_cron`, `pg_partman`), exporter on 9187 |
| `mariadb`, `mariadb_exporter` | `docker01` | MariaDB, exporter on 9104 |
| `database_tuning` | via `postgresql`, `mariadb` | sysctls, limits, THP |
| `k3s`, `k3s_registries` | `k8sdev01` | k3s + Harbor pull-through mirror |

## Firewall

- Rules: `host_config.<host>.firewall_rules`; `comment` required, `port`/`proto`/`from_ip` optional (no port = all ports for `from_ip`)
- Default: deny incoming
- UFW only filters host processes (sshd, PostgreSQL, node_exporter, NetBird client); **Docker-published ports bypass it** (FORWARD chain)
- No SSH rule: hosts are reached through NetBird, port 22 is closed
- On hosts in `netbird_hosts`: deny + enable **only while `netbird status` shows `Management: Connected`**, else a warning and the policy stays untouched (an active firewall stays active). Join NetBird first, then re-run
- Rules are never removed: delete by hand once (`ufw delete ...`) after removing from `firewall_rules`
- Check: `--tags firewall --check --diff`, compare with `ufw status verbose`

```yaml
host_config:
  docker01:
    firewall_rules:
      - { port: 9000, proto: tcp, from_ip: 172.16.0.0/12, comment: "RustFS S3 from the Docker networks" }
```

## NetBird client

- Role installs the client from the NetBird repo
- **Join by hand once** (one-time setup key from the dashboard, no secret in Git):

```bash
netbird up --setup-key <key> --management-url <url of the self-hosted server>
```

- Not connected: playbook only warns, firewall stays off

## k3s

| Item | Detail |
|---|---|
| Install | pinned `k3s_version`, official install script, `/etc/rancher/k3s/config.yaml` |
| Flags | keys of `host_config.<host>.k3s_config` (`node-ip` defaults to primary IPv4) |
| Registry mirror | role `k3s_registries` writes `/etc/rancher/k3s/registries.yaml` for `docker.io`, `ghcr.io` via Harbor; Harbor projects must be **public**, no credentials |
| Kernel | `/etc/sysctl.d/90-kubelet.conf` (`k3s_kernel_sysctls`): the parameters the kubelet expects (without `protect-kernel-defaults` it would set them itself, the file makes them persistent) |
| Etcd | embedded (`cluster-init`); snapshots only local in `/var/lib/rancher/k3s/server/db/snapshots`, **not backed up** |
| UFW | `k8sdev01` allows pod CIDR `10.42.0.0/16` and service CIDR `10.43.0.0/16`; rest closed |
| Istio | installed by hand, see [kubernetes.md](kubernetes.md#istio-installation) |

- Change a flag: edit `k3s_config`, `--tags k3s` (k3s restarts once, pods keep running)
- Upgrade: change `k3s_version`, dry run (`--tags k3s --check --diff`), then apply. Renovate only raises the version

## Node exporter and update monitoring

- Debian package `prometheus-node-exporter` on `docker01` and `k8sdev01`, textfile dir `/var/lib/prometheus/node-exporter`
- No node-exporter pod in the Prometheus stack (same port 9100; host textfile metrics only exist on the host)
- Prometheus scrapes job `node-exporter` (`kubernetes/monitoring/helm/prometheus.yaml`)
- Mounts of kubelet and k3s are excluded (`node_exporter_mount_points_exclude`)

`node-update-status.timer` (hourly) writes `node-update-status.prom`:

| Metric | Meaning |
|---|---|
| `node_reboot_required_since_timestamp_seconds` | since when a reboot is needed, `0` if none (`/var/run/reboot-required` or a newer kernel image than the running one) |
| `node_pending_updates{type="all\|security"}` | packages `apt-get --simulate dist-upgrade` would install |
| `node_unattended_upgrades_last_run_timestamp_seconds` | last unattended-upgrades run |

- Security updates install automatically, **never reboot** (`unattended_upgrades_reboot: false`): a reboot of `k8sdev01` stops all apps for a moment
- Alerts to Discord (`alert-rules-os-updates.yaml`): `RebootRequired` (>7 days), `UnattendedUpgradesStalled` (no run for 3 days), `SecurityUpdatesPending` (3 days)
- Reboot `k8sdev01` yourself in a quiet moment (`sudo reboot`)
- Check: `systemctl status prometheus-node-exporter node-update-status.timer`, `curl -s localhost:9100/metrics | grep -E "node_pending_updates|node_reboot"`

## Scheduled jobs

All systemd timers set up by Ansible (no cron):

| Timer | Host | When | What |
|---|---|---|---|
| `gitops-deploy.timer` | `docker01` | hourly 08:00-20:00 (`gitops_deploy_calendar`) | `deploy.sh --pull --metrics-file ...`, see [docker.md](docker.md#automatic-deploy) |
| `node-update-status.timer` | `docker01`, `k8sdev01` | 2 min after boot, then hourly | update metrics (above) |
| unattended-upgrades | all | apt default | security updates, no reboot |

Backups, offsite sync and Vault backup run as containers/CronJobs, see [backups.md](backups.md).

## Database tuning

Included at the end of `postgresql` and `mariadb`, per database:

- `/etc/sysctl.d/70-<database>.conf`: `vm.swappiness=1`, `vm.dirty_*`, `net.core.somaxconn`, `net.ipv4.tcp_keepalive_time`, `fs.aio-max-nr`
- systemd drop-in `limits.conf`: `LimitNOFILE`, `OOMScoreAdjust=-900` (containers die first)
- THP via `/etc/tmpfiles.d/transparent-hugepage.conf`: `madvise` (host-wide)
- `limits.conf` is not used (systemd ignores it); service restarts once when the drop-in changes
- Values: role `defaults/main.yml`
