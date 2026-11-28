# Ansible

Host setup for `docker01` (Docker host) and `k8sdev01` (k3s node). Run everything from `ansible/`.

## Run

| Step | Command |
|---|---|
| Install (Debian) | `sudo apt update && sudo apt install -y ansible git && git clone https://github.com/ToXiCCuss/gitops.git` |
| Collections | `cd gitops/ansible && ansible-galaxy collection install -r requirements.yml` |
| Dry run | `ansible-playbook -i inventory.ini site.yml --check --diff` |
| Apply | `ansible-playbook -i inventory.ini site.yml` |
| One role | add `--tags <firewall\|k3s\|node_exporter\|gitops_deploy\|postgresql_apply>` |

- Playbook runs **locally on each host** (`/root/gitops/ansible`), the checkout comes via `git pull`
- Hosts cannot push to Git; edit on the workstation
- No secrets in Ansible (no ansible-vault)

## Roles and hosts

Host lists are in `group_vars/all/main.yml`; per-host settings under `host_config.<host>`.

| Role | Hosts | Purpose |
|---|---|---|
| `base` | all | timezone, inotify limits, journal limit (500M, 14 days), unattended-upgrades (no auto reboot), SSH key-only for root |
| `netbird` | `docker01`, `k8sdev01` | install client; join is manual |
| `firewall` | `docker01`, `k8sdev01` | UFW from `host_config.<host>.firewall_rules` |
| `node_exporter` | `docker01`, `k8sdev01` | exporter + textfile collector + update status |
| `docker` | `docker01` | Docker CE, `daemon.json`, restart of socket containers |
| `gitops_deploy` | `docker01` | timer that runs `deploy.sh` |
| `gameserver_access` | `docker01` | SFTP users with SSH keys for the game server folders in `/srv/gameservers` |
| `postgresql`, `postgres_exporter` | `docker01` | PostgreSQL 18 (`pg_cron`, `pg_partman`), exporter on 9187 |
| `postgresql_apply` | `docker01` | timer that runs `apply_declared.sh` |
| `mariadb`, `mariadb_exporter` | `docker01` | MariaDB, exporter on 9104 |
| `database_tuning` | via `postgresql`, `mariadb` | sysctls, limits, THP |
| `k3s` | `k8sdev01` | k3s server configuration |

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
| Image pulls | k3s pulls from the registry named in each image reference |
| Node address | fixed `k3s_node_ip` (`10.254.0.1`) on the dummy interface `dummy0`, created by the unit `k3s-node-address.service` before every start of k3s. It is the `node-ip`, so a new **public** IP does not touch the cluster. The role refuses to change an existing `node-ip` (see [below](#change-the-node-address)) |
| Kernel | `/etc/sysctl.d/90-kubelet.conf` (`k3s_kernel_sysctls`): the parameters the kubelet expects (without `protect-kernel-defaults` it would set them itself, the file makes them persistent) |
| Etcd | embedded (`cluster-init`); snapshots only local in `/var/lib/rancher/k3s/server/db/snapshots`, **not backed up** |
| UFW | `k8sdev01` allows pod CIDR `10.42.0.0/16` and service CIDR `10.43.0.0/16`; rest closed |
| Istio | installed by hand, see [kubernetes.md](kubernetes.md#istio-installation) |

- Change a flag: edit `k3s_config`, `--tags k3s` (k3s restarts once, pods keep running)
- Upgrade: change `k3s_version`, dry run (`--tags k3s --check --diff`), then apply. Renovate only raises the version
- Retiring the Harbor mirrors: the `k3s` role removes `/etc/rancher/k3s/registries.yaml` when it contains exactly the former Ansible mirror configuration for Docker Hub and GHCR. The removal triggers a k3s restart. For a customized file, remove the old Harbor mirror entries manually, keep any registry credentials, and restart k3s

### Change the node address

Only needed **once** (the `node-ip` moves from the public IP to `k3s_node_ip`) or if the fixed address itself is ever changed. k3s does not start with a changed `node-ip`: the embedded etcd keeps the old peer address and k3s loops with "this server is not a member of the etcd cluster" (tested with k3s `v1.36.5+k3s1`). The role therefore stops with an error instead of rewriting `config.yaml`.

On `k8sdev01` as root. **All apps are down for a few minutes.**

1. Snapshot while k3s still runs (the local snapshots are not part of the backups): `k3s etcd-snapshot save --name vor-node-ip`
2. `systemctl stop k3s`. If k3s did not run (so no snapshot was possible) copy the etcd data cold instead: `cp -a /var/lib/rancher/k3s/server/db /root/k3s-db-vor-node-ip`
3. Create the address without touching k3s: `ansible-playbook -i inventory.ini site.yml --tags k3s_node_address`, check with `ip -4 addr show dummy0`
4. Set the new address in the config: `sed -i 's/^node-ip:.*/node-ip: 10.254.0.1/' /etc/rancher/k3s/config.yaml` (use the value of `k3s_node_ip`)
5. Reset the etcd membership: `k3s server --cluster-reset`. It reads `config.yaml`, keeps the data and exits after "restart without --cluster-reset flag now"
6. First start with the network policy controller off (otherwise k3s stops with "failed to find interface with specified node ip": the node object still holds the old IP until the kubelet has updated it): `echo 'disable-network-policy: true' >> /etc/rancher/k3s/config.yaml`, then `systemctl start k3s`. Wait until `kubectl get nodes -o wide` shows the new `INTERNAL-IP`
7. Remove the line again and restart: `sed -i '/^disable-network-policy:/d' /etc/rancher/k3s/config.yaml && systemctl restart k3s`
8. Check: `kubectl get nodes -o wide`, `kubectl get pods -A`, `kubectl get --raw /healthz/etcd`; then `ansible-playbook -i inventory.ini site.yml --tags k3s --check --diff` must show no change

Fallback if a step fails: restore the snapshot of step 1 (`k3s server --cluster-reset --cluster-reset-restore-path=<snapshot file in /var/lib/rancher/k3s/server/db/snapshots>`, see the k3s docs; not tested here). Steps 5-7 were tested in a local container with the pinned k3s version (the flag as command line argument, here as `config.yaml` key), not on the real host.

### Change the public IP

With the fixed node address the cluster does not care. Three steps:

1. Set the new IP (and gateway) in the network configuration of the host (depends on the hoster), check `ip -4 addr`, `ip route`, `ping -c 2 1.1.1.1`
2. `netbird status` must show `Management: Connected` (else `systemctl restart netbird`)
3. DNS: update the A records of the public hosts at Hetzner (public IP of `k8sdev01`, see [kubernetes.md](kubernetes.md#public-ingress-gateway)), check with `curl -I https://<host>`; check the cloud firewall of the hoster

Nothing to do for k3s, Prometheus, Ansible or Argo CD.

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

### Volume usage (k8sdev01)

The kubelet reports the usage of the whole disk for every `local-path` volume (the volumes are plain directories), so `kubelet_volume_stats_*` is useless here. `node-pvc-usage.timer` (every 15 minutes, only the hosts of `node_exporter_pvc_usage_hosts`) writes `node-pvc-usage.prom` from the directories `/var/lib/rancher/k3s/storage/pvc-<uid>_<namespace>_<name>`:

| Metric | Meaning |
|---|---|
| `node_pvc_used_bytes{namespace,persistentvolumeclaim}` | bytes the volume takes on the disk (`du`) |

- Dashboard "Volumes" (`kubernetes/monitoring/kubectl/dashboard-volumes.yaml`), no alert
- A volume whose PVC was deleted but whose directory is still there stays listed until the directory is gone
- Check: `systemctl status node-pvc-usage.timer`, `curl -s localhost:9100/metrics | grep node_pvc_used_bytes`

## Scheduled jobs

All systemd timers set up by Ansible (no cron):

| Timer | Host | When | What |
|---|---|---|---|
| `gitops-deploy.timer` | `docker01` | every 3 hours 08:00-20:00 (`gitops_deploy_calendar`) | `deploy.sh --pull --metrics-file ...`, see [docker.md](docker.md#automatic-deploy) |
| `postgresql-apply.timer` | `docker01` | every 3 hours 08:30-20:30 (`postgresql_apply_calendar`) | `apply_declared.sh --pull --metrics-file ...`, see [databases.md](databases.md#automatic-apply) |
| `node-update-status.timer` | `docker01`, `k8sdev01` | 2 min after boot, then hourly | update metrics (above) |
| `node-pvc-usage.timer` | `k8sdev01` | 3 min after boot, then every 15 minutes | volume usage metrics (above) |
| unattended-upgrades | all | apt default | security updates, no reboot |

Backups, offsite sync and Vault backup run as containers/CronJobs, see [backups.md](backups.md).

## Database tuning

Included at the end of `postgresql` and `mariadb`, per database:

- `/etc/sysctl.d/70-<database>.conf`: `vm.swappiness=1`, `vm.dirty_*`, `net.core.somaxconn`, `net.ipv4.tcp_keepalive_time`, `fs.aio-max-nr`
- systemd drop-in `limits.conf`: `LimitNOFILE`, `OOMScoreAdjust=-900` (containers die first)
- THP via `/etc/tmpfiles.d/transparent-hugepage.conf`: `madvise` (host-wide)
- `limits.conf` is not used (systemd ignores it); service restarts once when the drop-in changes
- Values: role `defaults/main.yml`

## Game server access

Role `gameserver_access`: people upload to the game server folders over SFTP with their own SSH key. The compose projects of the game servers are deployed by `deploy.sh` as usual; this role only handles the files.

- Folders: `/srv/gameservers/<server>` (`gameserver_access_servers`), owner UID 1000 (the user in the LinuxGSM container, `debian` on docker01), group `gs-<server>` (GID from 20000), mode `2770` (setgid: new files stay in the group, others see nothing). `/srv/gameservers` itself belongs to root: it is the SFTP chroot and sshd refuses the login otherwise. `/root` is not used, it is `0700`.
- Users: `gameserver_access_users` in `group_vars/all/main.yml` (name, UID from 2000, servers, `ssh_keys`). The account has no shell and is in exactly the groups of its servers. The keys are in `/etc/ssh/authorized_keys.d/<name>` and `exclusive`: only what is in Git works. The list is the desired state: a person removed from it loses the account, its primary group and its keys on the next run (files stay). This applies to every member of the group `gameserver-sftp`, so do not add other accounts to it.
- ACL: a game server container creates its own folders with umask `022`, so the group could not write there (`Permission denied` in WinSCP). The role sets an ACL on every server folder (`g:gs-<server>:rwX`, also as default entry, so new files inherit it regardless of the umask). It applies only to what a program creates with a write mode for the group (usually `0666`/`0777`); a file it creates as `0644` explicitly stays read-only for the group.
- sshd: drop-in `60-gameserver-sftp.conf` with `Match Group gameserver-sftp`: chroot, `internal-sftp -u 0002` (uploads are group-writable), no forwarding, no TTY. The key-only settings of `base` still apply.
- Containers: the LinuxGSM image sets its user to `UID`/`GID` (`default.env`) and takes ownership of `/data` on every start. Set `GID` to the GID of `gs-<server>` (`UID=1000`), so the group of the folder survives and the people with SFTP access keep their rights. Other images that do not change the owner need `group_add: ["<gid>"]` instead.
- Adding a server or person: extend the lists, merge, run the playbook (`--tags gameserver_access`, dry run first, see [Run](#run)).
- The entry `example-person` (no key, so nobody can log in) is a placeholder: replace it. The only server so far is `vhserver` ([docker/vhserver](../docker/vhserver/docker-compose.yml)).
- To be checked after the first run: `sshd -T -C user=<name>,host=x,addr=127.0.0.1 | grep -iE 'chroot|forcecommand'` shows the Match block, and an `sftp` login sees only `/<server>` folders. The `Match` block must end with its file (it is the last one in the drop-in and nothing else in the main `sshd_config` may fall under it).
