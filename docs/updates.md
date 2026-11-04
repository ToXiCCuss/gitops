# Updates (Renovate)

Renovate (GitHub app, `renovate.json`) opens a pull request for every new version once the release is 3 days old (`minimumReleaseAge`). It covers Helm charts and manifests of `kubernetes/`, images of `docker/` and `k3s_version` in `ansible/roles/k3s/defaults/main.yml`.

| What | How it is merged | Then |
|---|---|---|
| Digest + patch updates of `gcr.io/cadvisor/cadvisor`, `rclone/rclone`, `alpine` in `docker/` | **Renovate itself**, weekdays 9:00-17:00 (Europe/Berlin); no CI check in front | Docker host deploys within the next timer run ([docker.md](docker.md#automatic-deploy)); failure via `DockerDeploy*` alerts to Discord; rollback `git revert` |
| Everything else | by hand | merge to `master` is live in Argo CD (Kubernetes) or on the Docker host within minutes |
| k3s | PR only raises `k3s_version` | upgrade stays manual, dry run first ([ansible.md](ansible.md#k3s)); release candidates ignored |
| NetBird images | plain tags without digest (`netbird_rollback.sh` needs that); server, proxy, dashboard in one PR | merging changes nothing on the host, upgrade stays manual ([netbird.md](netbird.md#server)); check the validated Traefik/CrowdSec versions first |
| Istio (`istioctl`), Traefik bouncer plugin in `docker/netbird/docker-compose.yml` (`--experimental.plugins.bouncer.version`) | not tracked | by hand |

- A new auto-merge image is added on purpose to the `packageRules` of `renovate.json`: nothing is merged by default
