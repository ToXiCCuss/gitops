<#
.SYNOPSIS
    Vault-side preparation for Kubernetes auth: enables the kubernetes auth
    method, creates the KV v2 secrets engines this repo's consumers need,
    and writes the policies + auth roles for ArgoCD, Jenkins, Spring
    (dev/prod), and the Vault backup job.

.DESCRIPTION
    This is infrastructure prep only - it does NOT wire any app up to
    actually read from Vault at runtime (no Vault Agent injector, no app
    config changes). It just makes the auth backend + policies + roles
    exist, so that step can happen later, per-app, on its own.

    Needs kubectl configured against the target cluster (to read the
    cluster's API host/CA, and to mint a token-reviewer JWT for Vault).
    Creates a dedicated `vault-auth` ServiceAccount + ClusterRoleBinding
    (system:auth-delegator) in the Vault namespace if it doesn't exist yet.

.PARAMETER VaultAddr
    Vault API address reachable from this machine.

.PARAMETER VaultToken
    A Vault token with sufficient rights (sys/auth, sys/mounts, sys/policy,
    auth/kubernetes/*). Use the root token from init-vault.ps1, or a scoped
    admin token afterwards.

.PARAMETER Namespace
    Kubernetes namespace Vault (and the vault-auth ServiceAccount) runs in.
    Default: vault.

.EXAMPLE
    .\configure-vault-auth.ps1 -VaultAddr http://127.0.0.1:8200 -VaultToken s.xxxxx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultAddr,
    [Parameter(Mandatory)][string]$VaultToken,
    [string]$Namespace = "vault"
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }
$Audience = "https://kubernetes.default.svc.cluster.local"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# ── 0. Make sure kubectl is available ──────────────────────────────────────
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "kubectl not found on PATH - needed to read the cluster host/CA and mint the token-reviewer JWT." -ForegroundColor Red
    exit 1
}

# ── 1. Dedicated ServiceAccount for Vault's token review calls ────────────
Write-Step "Ensuring vault-auth ServiceAccount + ClusterRoleBinding exist"
$saManifest = @"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-auth
  namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-auth-delegator
subjects:
  - kind: ServiceAccount
    name: vault-auth
    namespace: $Namespace
roleRef:
  kind: ClusterRole
  name: system:auth-delegator
  apiGroup: rbac.authorization.k8s.io
"@
$saManifest | kubectl apply -f - | Out-Null
Write-Ok "vault-auth ServiceAccount + ClusterRoleBinding ready."

Write-Step "Minting a token-reviewer JWT for vault-auth"
$reviewerJwt = (kubectl create token vault-auth -n $Namespace --duration=87600h) | Out-String
$reviewerJwt = $reviewerJwt.Trim()
if (-not $reviewerJwt) {
    Write-Host "Failed to mint a token for vault-auth (needs kubectl 1.24+ for 'kubectl create token')." -ForegroundColor Red
    exit 1
}
Write-Ok "Got a long-lived (10y) reviewer token."

Write-Step "Reading cluster API host and CA from kubeconfig"
$kubernetesHost = (kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}').Trim()
$caDataB64 = (kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}').Trim()
if ($caDataB64) {
    $kubernetesCaCert = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($caDataB64))
} else {
    $caFile = (kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}').Trim()
    if ($caFile -and (Test-Path $caFile)) {
        $kubernetesCaCert = Get-Content $caFile -Raw
    } else {
        Write-Host "Could not determine the cluster CA cert from kubeconfig (no embedded data or file path)." -ForegroundColor Red
        exit 1
    }
}
Write-Ok "API host: $kubernetesHost"

# ── 2. Enable + configure the kubernetes auth method ───────────────────────
Write-Step "Enabling the kubernetes auth method (skipped if already enabled)"
$authMounts = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/auth" -Method Get -Headers $Headers
if ($authMounts.PSObject.Properties.Name -contains "kubernetes/") {
    Write-Ok "Already enabled."
} else {
    Invoke-RestMethod -Uri "$VaultAddr/v1/sys/auth/kubernetes" -Method Post -Headers $Headers -Body (@{ type = "kubernetes" } | ConvertTo-Json) -ContentType "application/json" | Out-Null
    Write-Ok "Enabled."
}

Write-Step "Writing kubernetes auth config"
$authConfigBody = @{
    token_reviewer_jwt   = $reviewerJwt
    kubernetes_host      = $kubernetesHost
    kubernetes_ca_cert   = $kubernetesCaCert
    disable_local_ca_jwt = $true
} | ConvertTo-Json
Invoke-RestMethod -Uri "$VaultAddr/v1/auth/kubernetes/config" -Method Post -Headers $Headers -Body $authConfigBody -ContentType "application/json" | Out-Null
Write-Ok "auth/kubernetes/config written."

# ── 3. KV v2 engines this repo's consumers read from ────────────────────────
Write-Step "Ensuring KV v2 secrets engines exist"
$mounts = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/mounts" -Method Get -Headers $Headers
foreach ($engine in @("argocd", "jenkins", "dev", "prod", "backup")) {
    $mountNames = @($mounts.PSObject.Properties.Name)
    if ($mounts.data) { $mountNames += @($mounts.data.PSObject.Properties.Name) }
    if ($mountNames -contains "$engine/") {
        Write-Ok "$engine/ already mounted."
    } else {
        $body = @{ type = "kv-v2" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$VaultAddr/v1/sys/mounts/$engine" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
        Write-Ok "$engine/ mounted (kv-v2)."
    }
}

# ── 4. Policies + kubernetes auth roles ─────────────────────────────────────
function Set-VaultPolicy {
    param([string]$Name, [string]$Hcl)
    $body = @{ policy = $Hcl } | ConvertTo-Json
    Invoke-RestMethod -Uri "$VaultAddr/v1/sys/policy/$Name" -Method Put -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
    Write-Ok "Policy '$Name' written."
}

function Set-VaultK8sRole {
    param([string]$Name, [string]$ServiceAccountNames, [string]$ServiceAccountNamespaces, [string]$Policies, [string]$Ttl = "24h")
    $body = @{
        bound_service_account_names      = $ServiceAccountNames
        bound_service_account_namespaces = $ServiceAccountNamespaces
        policies                         = $Policies
        ttl                              = $Ttl
        audience                         = $Audience
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$VaultAddr/v1/auth/kubernetes/role/$Name" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
    Write-Ok "Role '$Name' written (SA '$ServiceAccountNames' in '$ServiceAccountNamespaces')."
}

Write-Step "ArgoCD"
Set-VaultPolicy -Name "argocd" -Hcl @'
path "argocd/data/*" {
  capabilities = ["read"]
}
'@
Set-VaultK8sRole -Name "argocd" -ServiceAccountNames "argocd-repo-server" -ServiceAccountNamespaces "argocd" -Policies "argocd"

Write-Step "Jenkins"
Set-VaultPolicy -Name "jenkins" -Hcl @'
path "jenkins/data/*" {
  capabilities = ["read"]
}
'@
Set-VaultK8sRole -Name "jenkins" -ServiceAccountNames "default" -ServiceAccountNamespaces "jenkins" -Policies "jenkins"

Write-Step "Spring (dev)"
Set-VaultPolicy -Name "spring_dev" -Hcl @'
path "dev/data/*" {
  capabilities = ["read"]
}
'@
Set-VaultK8sRole -Name "spring_dev" -ServiceAccountNames "spring" -ServiceAccountNamespaces "dev" -Policies "spring_dev"

Write-Step "Spring (prod)"
Set-VaultPolicy -Name "spring_prod" -Hcl @'
path "prod/data/*" {
  capabilities = ["read"]
}
'@
Set-VaultK8sRole -Name "spring_prod" -ServiceAccountNames "spring" -ServiceAccountNamespaces "prod" -Policies "spring_prod"

Write-Step "Vault backup"
Set-VaultPolicy -Name "vault_backup" -Hcl @'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
path "backup/data/vault-backup" {
  capabilities = ["read"]
}
'@
Set-VaultK8sRole -Name "vault_backup" -ServiceAccountNames "vault-backup-sa" -ServiceAccountNamespaces "backup" -Policies "vault_backup"

Write-Step "Done"
Write-Ok "Auth backend, 4 KV engines, and 5 policy/role pairs are in place."
Write-Warn2 "Nothing reads from jenkins/dev/prod yet - that's app-side wiring (Vault Agent injector, Spring Cloud Vault, etc.) for a later step."
