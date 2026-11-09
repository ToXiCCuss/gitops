# Metabase and Edgerunner balance simulations

Metabase is enabled in the management and central secrets Argo sources. A master push
reconciles the application, gateway and Vault-backed secret automatically. Database provisioning
uses the separate PostgreSQL timer; Jenkins jobs still require manual commissioning.

## Components

- Management deployment: `kubernetes/management/kubectl/metabase.yaml`, official image `metabase/metabase:v0.64.1`.
- Internal URL: `https://metabase.k8sdev.rjst.de`, dedicated Istio listener **8455**, NetBird group `kubernetes-services`.
- Application database: `metabase` on `docker01.server.lan:5432`, login `metabase_owner`.
  Its owner role needs database `CREATE` (declared in `databases/postgresql.yaml`) so the initial
  migration can install the trusted `citext` extension; no superuser grant is needed.
- Analytics database: `edgerunner_balance`, separate logins `edgerunner_balance_writer` (rw) and `edgerunner_balance_metabase` (ro).
- Jenkins entry point: `balancePipeline()` in `cicd-library`; Edgerunner job Script Path `Jenkinsfile.balance`.

The application DB contains dashboards/accounts/saved connection credentials. It is separate from simulation data.
Existing PostgreSQL dump backups include both databases; retain the encryption key in Vault as well.

## Commissioning order (explicit rollout required)

1. The database declarations and balance tooling are on master in `gitops`, `cicd-library` and `edgerunner`. The Metabase manifests are active; ensure the prerequisites below are present when commissioning or restoring the platform.
2. Provision databases **before merging the Metabase application/secret manifests**. Either merge a database-only prerequisite commit first and wait for the existing timer, or explicitly authorize the established database scripts on docker01 (dry run first). This avoids an Argo secret render with missing Vault keys. Do not run database scripts from a Jenkins simulation job.
3. Use the existing secret-generation loop in `docs/vault.md`: the new `metabase encryption.secret_key` entry is generated once and never silently replaced.
4. Populate Vault `argocd/data/metabase` keys `database.username=metabase_owner` and `database.password` from `databases/postgresql/metabase_owner`. Keep values out of Git and terminal output. Argo's AVP can read only `argocd/`; copy credentials through the established administrator procedure.
5. Bootstrap `Tools/BalanceSim/schema.sql` from Edgerunner once as `edgerunner_balance_owner`, or `SET ROLE edgerunner_balance_role_owner` inside the schema session. The daily Jenkins job uses only the writer login and cannot migrate the schema.
6. Before the application manifests are merged, populate Vault `jenkins/data/edgerunner-balance`, key `BALANCE_DATABASE_URL`, using the writer login. Use the PostgreSQL TLS mode appropriate for docker01; never put the URL into a build parameter, Git, artifact or console. The existing Jenkins policy already reads this mount/path. No deploy service account or cluster rights are required.
7. Argo syncs `kubernetes/management/kubectl/metabase.yaml`, `metabase-gateway.yaml` and
   `kubernetes/secrets/metabase.yaml`. After sync, verify DNS/NetBird access and `/api/health`,
   then complete Metabase's first administrator setup. Local login is used initially; no paid SSO
   capability or Keycloak integration is assumed.
8. Add PostgreSQL data source `edgerunner_balance` in Metabase, host `docker01.server.lan`, port 5432, with `edgerunner_balance_metabase`. Do not use the owner or writer login. Let Metabase sync the typed `balance_*` views.
9. Create a dedicated Jenkins multibranch job with Script Path `Jenkinsfile.balance`. First test with the published `cicd-library` master on a trusted test branch. Enable publishing only after the schema exists. Branch builds archive data and validate it but do not load Vault secrets or publish; master/main builds can opt in via `PUBLISH_BALANCE`.

## Dashboards

Saved SQL cards are supplied in Edgerunner under `Tools/BalanceSim/metabase/`.
Start with the ten-minute success rate, survival by character/shop, evolution uptake, DPS upgrade curves,
and same-model commit comparisons. Add filters for project, commit, model version, batch, character,
evolution policy, shop and density as appropriate. Do not combine unlike scenarios into a single mean.

The first version imports audit aggregates and percentile summaries, not invented per-seed rows.
Each batch identifies its commit, source-model hash, parameters, seed range and build URL. Equal
reruns are deduplicated; different models/parameters remain separate. Data becomes visible only
after the complete import transaction commits. Failed simulations are diagnosed in Jenkins logs,
not presented as successful batches. A pipeline rerun must not double-count its previous results.

## Operations and rollback

- A normal balance run needs the .NET SDK and Python, not a Unity Editor/license or cluster API.
- Triggers are deliberately not installed automatically. Start manually; enable a Jenkins schedule or SCM
  trigger after the first successful run. No deployment or release stages exist in this pipeline.
- Jenkins' existing Vault role is shared across default agents; use trusted Jenkinsfile execution for
  jobs with secrets. The branch guard in this entry point does not redesign the platform's trust model.
- Resource settings are initial estimates; verify memory/startup duration after sync. Updates can migrate
  Metabase's application DB. Take a restorable backup before upgrades; image downgrade alone may not
  undo a DB migration. Preserve both DBs and the encryption key.
- Revert the Git change for an application rollback. The namespace has `Delete=false`; no PVC or database
  deletion is part of the rollback. Do not add `removed:` database declarations to roll this feature back.
- Local YAML/Groovy/Python validation does not prove NetBird routing, PostgreSQL grants, Vault keys,
  image startup or Jenkins CPS behavior. Those remain **to be checked after the sync / in a test job**.

Official deployment reference: https://www.metabase.com/articles/run-metabase-in-production-with-docker
