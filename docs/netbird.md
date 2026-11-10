# NetBird

NetBird is the VPN and reverse proxy: every internal app and both hosts are reached through it. Config of policies, zone and DNS stays **manual in the dashboard** (no Terraform).

| Part | Where |
|---|---|
| Server (self-hosted) | `docker/netbird/` on `docker01`, `/root/netbird` working folder |
| Client | Ansible role `netbird` ([ansible.md](ansible.md#netbird-client)) |
| Kubernetes operator | `kubernetes/infra/helm/kube-netbird-operator.yaml`, groups in `kube-netbird-access.yaml`, router in `kube-netbird-router.yaml`, API proxy in `kube-netbird-apiproxy.yaml` |
| Backup / restore / upgrade | [backup-services.md](backup-services.md#netbird-backup), [backups.md](backups.md#netbird) |

## Server

- Not in `ALL_PROJECTS`: **the deploy timer never touches it** (SSH and Vault run through NetBird; a broken merge must not lock you out)
- `pre-deploy.sh` installs the project files to `/root/netbird` and renders `config.yaml`, `proxy.env`, `crowdsec.env`, `traefik-dynamic.yaml` (mode 600) with the keys of Vault `docker/netbird`. They **stay on the host** (the server cannot read secrets from the environment; `/run` is empty after a reboot; NetBird must start without Vault)
- Named volumes and `crowdsec/` are not in Git, only `crowdsec/acquis.d/appsec.yaml` is installed
- Keys: `docker/netbird/vault.env.example`. A new server is restored with `netbird_restore.sh` (no Vault needed)

| Change | What to do |
|---|---|
| Config, labels, a secret | merge, `git pull` in `/root/gitops`, `sudo scripts/docker/deploy.sh netbird` |
| New image version (Renovate or by hand) | merge, `git pull`, `sudo scripts/netbird/netbird_upgrade.sh`, then `deploy.sh netbird` if a template changed too |

- `deploy.sh netbird` refuses an image change (needs the rollback point of `netbird_upgrade.sh`) and a `NETBIRD_STORE_ENCRYPTION_KEY` that differs from `/root/netbird/config.yaml` (database would become unreadable)
- After `netbird_rollback.sh` the host runs the old version while Git holds the new one: `git revert` the version change on `master`
- Images stay on plain tags without digest (`netbird_rollback.sh` needs that); server, proxy, dashboard come in one Renovate PR. Check validated Traefik/CrowdSec versions in the [upgrade docs](https://docs.netbird.io/selfhosted/maintenance/upgrade) before merging. The Traefik bouncer plugin version is not tracked by Renovate

### CrowdSec AppSec

Dashboard and routes `/api`, `/oauth2` go through the Traefik bouncer plugin and the CrowdSec AppSec WAF ([guide](https://docs.netbird.io/selfhosted/maintenance/crowdsec-dashboard)).

- Difference to the guide: the middleware is in `traefik-dynamic.yaml`, not a label (`deploy.sh` starts Compose in the repo folder and does not see a `.env` of `/root/netbird`; the key stays out of the Compose config)
- gRPC router and relay stay outside, so peers are not filtered. The Kubernetes operator uses `/api` and does pass the WAF
- With the `Block` flags a CrowdSec failure blocks dashboard, `/api`, `/oauth2`; Traefik only starts when CrowdSec is healthy
- Check after every label change, from an admin IP and **only these two paths** (two different rules within a minute ban the IP for 4 hours):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://proxy.rjst.de/.env       # 403
curl -s -o /dev/null -w '%{http_code}\n' https://proxy.rjst.de/api/.env   # 403
sudo docker exec netbird-crowdsec cscli bouncers list                     # netbird-proxy and netbird_dashboard
sudo docker exec netbird-crowdsec cscli metrics show appsec
```

- Protection **fails open**: with a detached middleware the probes answer `404` and nothing reports an error
- Locked out: `cscli decisions list` shows an IP decision (`cscli decisions delete --ip <ip>`); without one it is an AppSec match, see `cscli alerts list`. Last resort: remove **both** `middlewares` labels (`netbird-dashboard`, `netbird-dashboard-api`) in `/root/netbird/docker-compose.yml`, `docker compose up -d dashboard netbird-server` there (one label alone: UI loads but no login). Fix in Git afterwards, `deploy.sh netbird` installs the file again

## Configuration for Kubernetes

In Git (via the operator): groups `k8s-users` (peers that may reach every app) and `kubernetes-services` (every `NetworkResource`) in `kubernetes/infra/kubectl/kube-netbird-access.yaml`. No group per app: the policy `k8s-users` -> `kubernetes-services` decides.

By hand in the dashboard ([guide](https://docs.netbird.io/use-cases/kubernetes/route-to-a-kubernetes-service)):

1. `DNS > Zones > Add Zone`: domain `k8sdev.rjst.de` (separate internal zone; `proxy.rjst.de` is the NetBird host's public domain; a subdomain of `rjst.de` so Let's Encrypt DNS-01 can issue). Distribution group `k8s-users` (not a security boundary, policies are). The zone must exist before the `NetworkRouter` syncs
2. Records: the operator creates `<service>.<namespace>.k8sdev.rjst.de` per `NetworkResource`; add a CNAME per app to `gw-<app>.istio-internal.k8sdev.rjst.de`, e.g. `vault.k8sdev.rjst.de` -> `gw-vault.istio-internal.k8sdev.rjst.de`
3. `Access Control > Policies`: one policy, TCP 443, one-way `k8s-users` -> `kubernetes-services` (deny-by-default; the operator's `NBPolicy` creates nothing for `NetworkResource`s, deliberately unused)
4. `Peers`: put each peer/user into `k8s-users`. Machines too: k3s nodes (Harbor pull) and `docker01` (Vault)

- Router: one routing peer (`workloadOverride.replicas: 1`, single-node cluster); 3+ for failover
- A re-joined peer loses its groups (then `server.lan` names give NXDOMAIN): re-add it
- The Forgejo backup pod uses `docker01.server.lan:9000` through NetBird: the node needs a policy for `docker01` on TCP 9000.

## Internal apps

Each app is `https://<app>.k8sdev.rjst.de` (443, Let's Encrypt wildcard `*.k8sdev.rjst.de` via ClusterIssuer `letsencrypt`, DNS-01 at Hetzner). `istio-internal-gateway` (`infra/helm`) is a second ingress gateway, ClusterIP only: nothing outside the cluster reaches it except via the NetBird routing peer.

NetBird separates access per destination, not per hostname, so every app has its own Service, listener port on the gateway and `NetworkResource` (`infra/kubectl/kube-istio-internal.yaml`); a listener only accepts that app's host. Gateway, VirtualService and `NetworkResource` live next to the app (`kube-gw-argocd.yaml` in `infra`, the others in their domain's `kubectl/`). Each app needs its CNAME.

| App | URL | Backend | Listener |
|---|---|---|---|
| Argo CD | `argocd.k8sdev.rjst.de` | `argocd-server.argocd:80` | 8444 |
| Vault | `vault.k8sdev.rjst.de` | `vault.vault:8200` | 8443 |
| Grafana | `grafana.k8sdev.rjst.de` | `grafana.prometheus:80` | 8445 |
| Harbor | `harbor.k8sdev.rjst.de` | `harbor.harbor:80` | 8446 |
| Jenkins | `jenkins.k8sdev.rjst.de` | `jenkins.jenkins:8080` | 8447 |
| Developer Portal | `developer-portal.k8sdev.rjst.de` | `developer-portal.developer-portal:7007` | 8448 |
| Prometheus | `prometheus.k8sdev.rjst.de` | `prometheus-prometheus.prometheus:9090` | 8452 |
| Forgejo | `forgejo.k8sdev.rjst.de` | `forgejo-http.forgejo:3000` | 8453 |

- Ports 8443-8453 serve platform apps here; 8454 is free. Ports 9000-9999 are Spring apps (`kubernetes-values/PORTS.md`)
- Nodes pull from Harbor through NetBird: valid certificate, no insecure-registry setting; put the node peers into `k8s-users`

## kubectl through NetBird

`infra/kubectl/kube-netbird-apiproxy.yaml` deploys the operator's `ClusterProxy` `k8sdev` ([API server proxy](https://docs.netbird.io/use-cases/kubernetes/api-server-proxy)). The proxy pod is a peer in group `k8s-api-proxy`; it forwards `kubectl` requests and impersonates the caller (Kubernetes user = NetBird user, groups = the **user's** NetBird groups). No credentials in a kubeconfig.

- RBAC decides: one binding so far, NetBird group `k8s-cluster-admins` -> `cluster-admin`
- The proxy service account may impersonate any user and group: the pod is as sensitive as `cluster-admin`

By hand in the dashboard:

1. `Team > Users > <your user> > Auto-assigned groups`: add `k8s-cluster-admins` (the **user** must be in the group, peers do not count)
2. `Access Control > Policies`: `k8s-cluster-admins` -> `k8s-api-proxy` (port: look in the proxy pod, `kubectl -n netbird get pods`)

On your machine (NetBird CLI >= 0.79):

```bash
netbird kubernetes list
netbird kubernetes write-kubeconfig k8sdev
kubectl --context k8sdev get pods -A
```
