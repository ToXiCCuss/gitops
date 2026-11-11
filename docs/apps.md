# Apps

Setup that goes beyond "merge and sync". Common pattern for apps with Keycloak login and a database:

| Step | Where |
|---|---|
| Database | declare in `databases/postgresql.yaml` (`apply_declared.sh`) or `db_create.sh <name>` on `docker01`; owner password lands in Vault `databases/...` |
| Generated secrets | `scripts/vault/Generate-Secrets.ps1` and DB-copy block in [vault.md](vault.md#secrets) |
| Keycloak client | `docker/keycloak-config/realms/rjst.yaml`, secret into Vault `docker/keycloak-config` **before the merge**, then `deploy.sh keycloak-config` ([keycloak.md](keycloak.md#realm-as-code)) |
| NetBird | CNAME `<app>` in the zone ([netbird.md](netbird.md#configuration-for-kubernetes)) |

## Jenkins

`cicd/helm/jenkins.yaml` configures Jenkins as code; a new pod or fresh volume needs no UI setup except one job.

| Part | Detail |
|---|---|
| Plugins | `controller.additionalPlugins` |
| Credential `github-app` | JCasC in its own ConfigMap `kubernetes/cicd/kubectl/jenkins-casc.yaml` (sidecar loads ConfigMaps labelled `jenkins-jenkins-config`); App ID `1161269`. Private key from Vault `argocd/data/jenkins#github_app_private_key` -> Secret `jenkins-github-app` (`kubernetes/secrets/jenkins-github-app.yaml`), mounted as a file, read with `readFile` |
| Shared library | `cicd-library` (`https://github.com/RJST-DEVELOP/cicd-library.git`, `master`, not implicit, credential `github-app`) |
| By hand, once | job `RJST-DEVELOP`: New Item, GitHub Organization, owner `RJST-DEVELOP`, credentials `github-app` |
| Build history | only in the Jenkins volume, not backed up |

- **No `$` in the Helm values of Jenkins** (`HELM_VALUES`): Argo CD replaces `$NAME`/`${NAME}` in plugin env values and an unknown name becomes an empty string (JCasC placeholders arrive as `""`)
- New private key (e.g. old file lost): generate in the GitHub App settings (**Generate a private key**, several can coexist, no API), convert to unencrypted PKCS#8 PEM, write to Vault (other keys stay), delete the file, restart Jenkins (it does not notice a changed Secret while running). `kv_set` is defined in [vault.md](vault.md#secrets):

```bash
openssl pkcs8 -topk8 -nocrypt -in <downloaded>.pem | kv_set -mount=argocd jenkins github_app_private_key=-
rm <downloaded>.pem
kubectl -n jenkins rollout restart statefulset jenkins
```

## Harbor

In each Harbor project that receives builds, open **Policy → Tag Retention** and add these rules. Both use **Repositories matching** `**` and retain the 5 most recently pushed artifacts per repository. Leave **Untagged artifacts** unchecked in both rules.

| Builds | Tag filter |
|---|---|
| Snapshots | **matching** `*SNAPSHOT*` |
| Releases | **excluding** `*SNAPSHOT*` |

Run **Dry Run** and review the affected artifacts before enabling a schedule. Harbor keeps every tag on a retained digest. To retain multiple snapshot builds, push each build with a distinct tag containing `SNAPSHOT`. [Harbor retention rules](https://goharbor.io/docs/2.15.0/working-with-projects/working-with-images/create-tag-retention-rules/)

In **Administration → Clean Up → Garbage Collection**, enable **Allow garbage collection on untagged artifacts** and run **Dry Run** before scheduling collection. Garbage collection applies to the whole registry and frees storage used by unreferenced blobs. [Harbor garbage collection](https://goharbor.io/docs/2.15.0/administration/garbage-collection/)

## Forgejo

`cicd/helm/forgejo.yaml`: Forgejo (LTS, rootless) as package registry for own libraries (Maven; npm/Helm if needed). Container images stay in Harbor, Git stays on GitHub: SSH and Actions are off. The chart recreates config, the local admin `localadmin` (emergency login, password from Vault) and auth source `keycloak` at every start. Keycloak login only, no registration, no anonymous access.

- **Before the first sync:** `scripts/postgresql/db_create.sh forgejo` on `docker01`, then `Generate-Secrets.ps1 -Mount argocd` creates `argocd/data/forgejo` (`admin.password`, `oidc.client_secret`, `security.secret_key`, `security.internal_token`), last block copies DB user and password. **Never change `security.secret_key`** (encrypts auth-source secret, 2FA)
- **Keycloak:** client `forgejo`, secret `FORGEJO_CLIENT_SECRET` (`vault kv get -field=oidc.client_secret argocd/forgejo`). Client role `forgejo` `user` or `admin` (`admin` = site admin); a user without one is refused. First login creates the user (claim `nickname`)
- **NetBird:** CNAME `forgejo`
- **Maven:** packages belong to a user or organization (e.g. `rjst`). URL `https://forgejo.k8sdev.rjst.de/api/packages/<owner>/maven` for `<distributionManagement>` (releases and snapshots) and `<repositories>`. Login with the Forgejo username + access token with scope `package` (**Settings > Applications**) in a `<server>` of `settings.xml`, never the Keycloak password. Pods reach the URL through the CoreDNS rewrite to the internal gateway

### Backup and restore

CronJob `forgejo-backup` (`cicd/kubectl/forgejo-backup.yaml`, [Forgejo guide](https://forgejo.org/docs/latest/admin/setup/backup/)), nightly 02:00 UTC: scale Forgejo to 0, `pg_dump --clean`, dump + data volume in **one** restic snapshot (repository `forgejo/restic`, host `forgejo`), start Forgejo (1-2 min without registry), then forget (14d/8w/6m) and prune. `restic-backup` checks the repository at 03:00, offsite sync copies it at 05:00.

- `app.ini` not in the backup (the chart rebuilds it; `SECRET_KEY` is in Vault, covered by `vault-backup`). The SQL dump of `restic-backup` covers the database a second time
- Application ignores `spec.replicas` of the Deployment (`ignoreDifferences` + `RespectIgnoreDifferences`), so Argo CD does not start it during the backup; the script's trap restarts it on failure. If it stays at 0 (pod killed) `ProbeFailed` on `forgejo.k8sdev.rjst.de` fires: `kubectl -n forgejo scale deployment forgejo --replicas=1`
- Alerts: `CronJobBackupFailed`, `CronJobBackupTooOld` (26 h), `CronJobBackupNeverReported` (kube-state-metrics), `ResticStepFailed` of the nightly check
- Set up before the merge (admin token): S3 keys of identity `forgejo`, restic password `argocd/forgejo#backup.restic_password` and the copies (S3 keys to `argocd/forgejo`, restic password to `docker/restic-backup#RESTIC_PASSWORD_FORGEJO`) come with [vault.md](vault.md#secrets). Keep the restic password in the password manager. Without these values the Secret `forgejo-backup` cannot render and the `secrets` app fails
- After the merge on `docker01` (checkout with the new `docker/rustfs/identities.json`): `sudo scripts/docker/setup-rustfs.sh` (bucket + identity `forgejo`, rights of `restic-backup`/`offsite-sync`), `sudo scripts/docker/deploy.sh restic-backup`, before the first run at 02:00 UTC
- Pods reach the S3 as `docker01.server.lan:9000` through NetBird: the node needs a policy for `docker01` on TCP 9000
- Test: `kubectl -n forgejo create job forgejo-backup-test --from=cronjob/forgejo-backup`, `kubectl -n forgejo logs -f job/forgejo-backup-test`

Restore (replaces data volume and database; on a failing step Forgejo stays stopped on purpose, fix and re-run):

1. Pick the snapshot on `docker01`: `sudo scripts/docker/restore.sh snapshots forgejo` (S3 gone: `--from pcloud`; the cluster job itself needs the S3)
2. Newest snapshot via the suspended CronJob:

```bash
kubectl -n forgejo create job forgejo-restore-$(date +%s) --from=cronjob/forgejo-restore
```

   Older snapshot: `kubectl -n forgejo create job forgejo-restore-1 --from=cronjob/forgejo-restore --dry-run=client -o yaml | kubectl set env --local -f - SNAPSHOT=<id> -o yaml | kubectl apply -f -`
3. `kubectl -n forgejo logs -f job/<name>`, log in, check a package. If the search index looks wrong run the cron jobs under **Site administration > Monitoring > Cron**

## Developer Portal

Backstage as our own build (repository `developer-portal` in RJST-DEVELOP), deployed by Jenkins like the Spring apps: build image, push to Harbor, `helm upgrade --install developer-portal` of chart `ghcr.io/backstage/charts/backstage` into namespace `developer-portal`. Replaces the Portal step by step (both run side by side). This repo holds only the frame:

| File | Content |
|---|---|
| `management/kubectl/developer-portal.yaml` | Gateway (8448), Service, VirtualService, NetBird resource, groups `k8s-developer-portal`, `developer-portal-users`. VirtualService targets `developer-portal:7007`; chart default is `<release>-backstage`, so the pipeline sets `fullnameOverride: developer-portal` |
| `secrets/namespaces.yaml`, `secrets/developer-portal.yaml` | namespace and environment (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `AUTH_OIDC_CLIENT_SECRET`, `BACKEND_SECRET`, `GITHUB_APP_*`); chart reads it with `extraEnvVarsSecrets` |
| `cicd/kubectl/helm-deployer.yaml` | Role of `helm-deployer` in `developer-portal`, namespaced, no RBAC |

Before the first deploy:

- **Database:** `developer_portal` is declared in `databases/postgresql.yaml` (`apply_declared.sh`, or `db_create.sh developer_portal`; underscores only), then `Generate-Secrets.ps1 -Mount argocd` creates `argocd/data/developer-portal` (`oidc.client_secret`, `backend.secret`), last block copies DB user and password. Backstage creates a database per plugin unless `backend.database.pluginDivisionMode` is `schema`: set it, else the login needs the right to create databases. The chart's PostgreSQL subchart stays off
- **Keycloak:** client `developer-portal` with roles `admin` and `user`; a user without one is refused: assign in the UI (**Users > Role mapping**) before the first login. Secret `DEVELOPER_PORTAL_CLIENT_SECRET` (`vault kv get -field=oidc.client_secret argocd/developer-portal`) before the merge
- **NetBird:** CNAME `developer-portal`
- **Order:** Gateway and VirtualService exist after the merge; the app answers once Jenkins deployed the release. Add the probe in `monitoring/kubectl/probes.yaml` with the first release, not before (it would alert until then)
