# Keycloak

Login for all apps. Runs on the **Docker host, not in the cluster**, on purpose: it must not depend on the cluster, Argo CD or Vault, and a rebuilt cluster does not touch it.

| Item | Detail |
|---|---|
| Project | `docker/keycloak`, `docker/keycloak-config` |
| Public URL | `https://auth.proxy.rjst.de` (NetBird reverse proxy, TLS ends there). It is the issuer in every token: choose once, Keycloak serves one URL only |
| Database | local PostgreSQL (`host.docker.internal`), dumped by `restic-backup` (users and group membership live only there) |
| Realm | `rjst`, issuer `https://auth.proxy.rjst.de/realms/rjst` |
| Emergency logins | every app keeps a local one (Argo CD `admin`, Jenkins admin, Harbor `admin`, Vault root token, Grafana admin) |

## Setup

1. On the Docker host: `scripts/postgresql/db_create.sh keycloak` (password of `keycloak_owner` goes to Vault `databases/postgresql/keycloak_owner`)
2. Vault secret `docker/keycloak` (`vault kv put docker/keycloak ...`, names in `docker/keycloak/vault.env.example`): DB user and password (`vault kv get -field=password databases/postgresql/keycloak_owner`), password of the first admin (`openssl rand -base64 24`, keep in the password manager)
3. `sudo scripts/docker/deploy.sh keycloak`
4. NetBird dashboard: reverse proxy service `auth.proxy.rjst.de` to port `8180` of the Docker host, restricted to your peers (this keeps Keycloak internal; the published port `8180` itself is open like the other Docker ports)
5. Log in as `admin` at `https://auth.proxy.rjst.de/admin/`, create a personal admin in realm `master` (role `admin`), delete `admin` (bootstrap variables are only read while `master` has no user). Create a separate realm for the apps

## Realm as code

`docker/keycloak-config/realms/rjst.yaml` holds realm `rjst`, client roles and one client per app. Project `keycloak-config` is a one-shot job ([keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli)) that applies the file through the admin API and exits. `deploy.sh keycloak-config` runs it; the import is idempotent, only what the job created itself is removed when it disappears from the file.

- Image is built for Keycloak 26.5.5, the server is newer (26.6.x): if an import fails, look there first
- **Not in the file:** users, passwords, group membership (created in the UI, live in the database)
- Permissions per app via client roles (Grafana: `admin`, `editor`, `viewer`); assign under **Users > Role mapping > Client roles**, or via a group (roles inherited). A user without an app's role is refused by that app only
- A role change is effective at the next login. A mapper puts the roles into the token as claim `roles`; the app maps them (Grafana: `role_attribute_path` in `kubernetes/monitoring/helm/prometheus.yaml`). Apps create their user at first login
- Client secrets are generated into Vault ([vault.md](vault.md#secrets)) and **copied into Vault `docker/keycloak-config`** as `<APP>_CLIENT_SECRET`; the file refers to `$(env:GRAFANA_CLIENT_SECRET)`. The variable is required: without it the deploy timer fails on `keycloak-config`
- `docker/keycloak-config` also needs a realm-`master` user with role `admin` (`KEYCLOAK_USER`, `KEYCLOAK_PASSWORD`)

| App | Secret source in Vault | Variable in `docker/keycloak-config` |
|---|---|---|
| Grafana | `argocd/data/prometheus#oidc.client_secret` | `GRAFANA_CLIENT_SECRET` |
| Argo CD | `argocd/data/argocd#oidc.client_secret` | `ARGOCD_CLIENT_SECRET` |
| Vault | `argocd/data/vault#oidc.client_secret` | `VAULT_CLIENT_SECRET` |
| Forgejo | `argocd/data/forgejo#oidc.client_secret` | `FORGEJO_CLIENT_SECRET` |
| Developer Portal | `argocd/data/developer-portal#oidc.client_secret` | `DEVELOPER_PORTAL_CLIENT_SECRET` |
| RustFS | typed (`openssl rand -base64 32`) | `RUSTFS_CLIENT_SECRET` |

New app: add a client block with roles and mapper to the file, secret in Vault and in `docker/keycloak-config` (new variable in `default.env` and `vault.env.example`), `sudo scripts/docker/deploy.sh keycloak-config`, check `docker logs keycloak-config`.

## Argo CD login

Argo CD is not rendered by AVP: `oidc.config` in `kubernetes/argocd-values.yaml` refers to Secret `argocd-oidc` (`kubernetes/secrets/argocd-oidc.yaml`). Roles: `admin` = `role:admin`, `viewer` = `role:readonly`; a user without a role sees nothing. Browser only (confidential client: `argocd login --sso` does not work, use local `admin` for the CLI).

1. Copy the client secret into Vault `docker/keycloak-config` as `ARGOCD_CLIENT_SECRET`: `vault kv get -field=oidc.client_secret argocd/argocd` (before the merge)
2. Merge, then `sudo scripts/docker/deploy.sh keycloak-config`
3. Hard refresh the Argo CD app `secrets` (a plain refresh does not pick up the new Vault value)
4. Apply `kubernetes/argocd-values.yaml` with the `helm upgrade` ([kubernetes.md](kubernetes.md#1-bootstrap-argo-cd))
5. Keycloak UI: give your user client role `admin` of client `argocd`, log in with **Log in via Keycloak**

Pods fetch token and user info from `https://auth.proxy.rjst.de`, so the cluster must reach it. Test: `kubectl -n prometheus exec deploy/grafana -c grafana -- wget -qO- https://auth.proxy.rjst.de/realms/rjst/.well-known/openid-configuration`.
