# AGENTS.md – GitOps (external apps via Argo CD, Ansible and Docker)

Extends the global instructions (`~/.claude/CLAUDE.md` or `~/.codex/AGENTS.md`). Fill in project-specific details at the bottom.

## Scope
- This repo is only for **external (third-party) apps**, deployed via Argo CD (Kubernetes: Vault, Harbor, Jenkins, Kafka, Prometheus, cert-manager, NetBird, Argo itself), Ansible (hosts) or Docker Compose (Docker host).
- **Own Spring applications** are never deployed from here: Jenkins deploys them with Helm (repos `cicd-library`, `kubernetes-values`, `spring-boot-chart`). Only the deployer's permissions live here (`kubernetes/spring/kubectl/helm-deployer.yaml`).
- Layout: `kubernetes/` (Argo CD), `ansible/` (hosts, roles), `docker/` (Compose projects), `databases/` (declared PostgreSQL access of docker01), `scripts/`, `tofu/` (OpenTofu: Proxmox VMs, state in PostgreSQL), `istio/` (input for a manual `istioctl install`, not synced by Argo CD).

## Core principle
- Git is the source of truth. All Applications run with `automated` (`prune` and `selfHeal`) on `targetRevision: master`: **a merge to `master` is a live deployment.** Prepare changes on a branch; never commit, push or merge without a request.
- Never run `kubectl apply`, `edit`, `patch`, `delete` or `helm install/upgrade` against the cluster. Any cluster access needs your approval first, even read-only (`get`, `describe`, `logs`), and only with a verified context (`kubectl config current-context`); access goes through the NetBird API proxy.
- Do not repair drift in the cluster (`selfHeal` would revert it anyway); fix it in Git or report it.

## Structure (app of apps)
- `kubernetes/kube-app-<domain>.yaml`: one Argo Application per domain (`cicd`, `infra`, `kafka`, `management`, `monitoring`, `secrets`, `spring`); it points to `kubernetes/<domain>/apps.yaml`.
- `kubernetes/<domain>/apps.yaml`: two Applications, `<domain>-helm` (sync wave 0) and `<domain>-kubectl` (sync wave 1). Helm charts come before the plain manifests.
- `<domain>/helm/<app>.yaml`: one Application per third-party chart (`repoURL` = chart repo, `targetRevision` = chart version, values inline via `plugin.env: HELM_VALUES`). `<domain>/kubectl/*.yaml`: plain manifests (CRDs, gateways, RBAC, network rules).
- Naming: file and Application names in lowercase `kebab-case`; Helm apps are named after the chart (`cert-manager.yaml`). Follow the neighboring files in the folder (e.g. `infra/kubectl` uses `kube-<topic>.yaml`).
- New domain = new `kube-app-<domain>.yaml` plus a folder with `apps.yaml`, `helm/`, `kubectl/`. Order of commissioning: section "Deployment Guide" in `README.adoc`.
- `kubernetes/archive/` and `kubernetes/parked/` are not deployed and are not touched.
- Internal gateway ports 8443–8451 belong to the platform apps here; 9000–9999 are Spring apps (`kubernetes-values/PORTS.md`). No overlap.

## Rules for changes
- Pin chart versions exactly (`targetRevision: v1.2.3`), never `*`, `latest` or branches. Renovate raises versions (minimum age 3 days); do not guess or raise them by hand without a request.
- New Applications: `project: default`, `CreateNamespace=true`, resource requests and limits like the existing charts, explicit namespace.
- Deleting a file means deleting the resource (`prune`). For resources with data or dependencies (PVC, namespace, operators, CRDs, Vault) only after explicit confirmation.
- Never read or edit huge upstream files (`monitoring/crds/prometheus-crds.yaml`, `kafka/kubectl/kube-apicurio-registry-operator.yaml`) completely, only search them in a targeted way.
- Rights for the Jenkins deployer (`helm-deployer`) stay namespaced and without RBAC or cluster-wide permissions. If the chart needs a new resource type, extend the role identically in `dev` and `prod` (there is no `qa` yet).

## Secrets
- No plaintext secrets in Git, not even base64. Runtime secrets live in Vault; Ansible secrets are encrypted in `ansible/group_vars/all/secrets.yml` (ansible-vault).
- Never read, print or commit: `ansible/.vault_pass`, `override.env` (only on the server, gitignored). Do not fill secrets manifests under `kubernetes/secrets/` with real values.
- Found a plaintext secret: report it, do not delete it silently (it is in the history, rotate the secret).

## Ansible and Docker
- Ansible: dry run first (see `README.adoc`, section "Dry Run"), apply only on explicit request. I do not touch the vault password.
- Database access is declared in `databases/postgresql.yaml`; `scripts/postgresql/apply_declared.sh` applies it on docker01 (`--dry-run` first). I change the file, I do not run the script against the host unless asked.
- Docker projects: defaults in `default.env`, overrides in `override.env` (not in Git, keep the template `override.env.example` up to date).

## Check before "done" (local, without cluster)
- YAML valid and schema-checked: `kubeconform -strict -ignore-missing-schemas` on changed `kubectl/` manifests, `yamllint` on all changed files.
- Paths and names in `apps.yaml`/`kube-app-*.yaml` match the folders, sync waves are in the right order.
- State the result of the check. What can only be verified in the cluster, name as "to be checked after the sync".
- In the PR description state: affected domains, impact (restart, downtime, data migration) and rollback (`git revert`).

## Project-specific
<!-- Cluster, hosts, specifics of this setup -->

<!-- file-type-rules:start -->
## File-type rules
Before creating or editing a file that matches a pattern, read the rule file and follow it.
- `**/*.ps1`, `**/*.psm1`, `**/*.psd1`: `.claude/rules/powershell.md`
- `**/*.sh`, `**/*.bash`: `.claude/rules/shell.md`
<!-- file-type-rules:end -->
