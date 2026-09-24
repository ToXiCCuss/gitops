<#
.SYNOPSIS
    Generates/collects the app secrets listed in kubernetes/README.adoc and
    writes them into Vault (KV v2), so ArgoCD's AVP plugin can render them.

.DESCRIPTION
    - Freely generatable secrets (Harbor/Jenkins/Grafana admin passwords)
      are generated locally and written straight to Vault.
    - The Hetzner API token is applied straight into the cluster as a
      standalone Secret instead of going to Vault (like vault-unsealer-config)
      - via kubectl, not GitOps/AVP, see kubernetes/infra/kube-clusterissuer.yaml.
    - Nothing is written to disk by this script.
    - The rest (NetBird PAT, the docker01 DB credentials for
      Harbor/Keycloak/Microcks, and the vault-backup CronJob's restic
      password + rclone.conf) go to Vault and are prompted for
      interactively. Leave blank to skip a value - existing Vault data for
      that key is left untouched.
    - Safe to re-run: it never overwrites a key you leave blank, and asks
      before overwriting one you do provide if it already has a value.

.PARAMETER VaultAddr
    Vault API address reachable from this machine.

.PARAMETER VaultToken
    A Vault token with write access to argocd/data/*. Use the root token
    from init-vault.ps1 for a first run, or a scoped token afterwards.

.EXAMPLE
    .\generate-secrets.ps1 -VaultAddr http://127.0.0.1:8200 -VaultToken s.xxxxx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultAddr,
    [Parameter(Mandatory)][string]$VaultToken
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function New-RandomSecret {
    param([int]$Length = 32)
    $bytes = New-Object byte[] $Length
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Get-VaultKV {
    param([string]$Path, [string]$Engine = "argocd")
    try {
        $resp = Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Get -Headers $Headers
        if ($resp.data.data) {
            $ht = @{}
            foreach ($p in $resp.data.data.PSObject.Properties) { $ht[$p.Name] = $p.Value }
            return $ht
        }
    } catch {
        # 404 = path has no data yet, which is fine on a first run
    }
    return @{}
}

$script:EnsuredEngines = @{}
function Confirm-KVEngine {
    param([string]$Engine)
    if ($script:EnsuredEngines.ContainsKey($Engine)) { return }
    $mounts = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/mounts" -Method Get -Headers $Headers
    $names = @($mounts.PSObject.Properties.Name)
    if ($mounts.data) { $names += @($mounts.data.PSObject.Properties.Name) }
    if ($names -notcontains "$Engine/") {
        $body = @{ type = "kv-v2" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$VaultAddr/v1/sys/mounts/$Engine" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
        Write-Ok "Created missing KV v2 engine '$Engine/'."
    }
    $script:EnsuredEngines[$Engine] = $true
}

function Set-VaultKV {
    param([string]$Path, [hashtable]$Data, [string]$Engine = "argocd")
    Confirm-KVEngine -Engine $Engine
    $existing = Get-VaultKV -Path $Path -Engine $Engine
    $merged = @{}
    foreach ($k in $existing.Keys) { $merged[$k] = $existing[$k] }
    foreach ($k in $Data.Keys) {
        if ([string]::IsNullOrEmpty($Data[$k])) { continue }  # never write blanks over existing data
        if ($merged.ContainsKey($k) -and $merged[$k] -eq $Data[$k]) { continue }
        if ($merged.ContainsKey($k)) {
            $confirm = Read-Host "  $Engine/data/$Path#$k already has a value. Overwrite? [y/N]"
            if ($confirm -notmatch '^[yY]') { continue }
        }
        $merged[$k] = $Data[$k]
    }
    $body = @{ data = $merged } | ConvertTo-Json
    Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
    Write-Ok "$Engine/data/$Path updated ($($Data.Keys -join ', '))"
}

function Read-OptionalSecret {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    if ($secure.Length -eq 0) { return "" }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Set-K8sSecret {
    param([string]$Name, [string]$Namespace, [hashtable]$StringData)
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-Warn2 "kubectl not found on PATH - skipping Secret '$Name' (nothing is saved to disk)."
        return
    }
    $lines = foreach ($k in $StringData.Keys) { "  ${k}: $($StringData[$k] | ConvertTo-Json -Compress)" }
    $yaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: $Name
  namespace: $Namespace
type: Opaque
stringData:
$($lines -join "`n")
"@
    $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    Write-Ok "kubectl context: $(kubectl config current-context)"
    # The namespace may not exist yet at bootstrap (e.g. cert-manager, created later by ArgoCD).
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null
    $yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to apply Secret '$Name' in namespace '$Namespace'." -ForegroundColor Red
        exit 1
    }
}

# ── 1. Freely generatable app passwords ────────────────────────────────────
Write-Step "Generating app-internal admin passwords"
Set-VaultKV -Path "harbor" -Data @{ "admin.password" = (New-RandomSecret) }
Set-VaultKV -Path "jenkins" -Data @{ "password" = (New-RandomSecret) }
Set-VaultKV -Path "prometheus" -Data @{ "password" = (New-RandomSecret) }

# ── 2. External values that must match reality - prompt, never generate ───
Write-Step "External values (leave blank to skip / keep existing)"

$hetznerToken = Read-OptionalSecret "Hetzner Cloud API token (DNS read/write, blank to skip)"
if ($hetznerToken) {
    # Applied directly via kubectl, not GitOps/AVP - see kubernetes/infra/kube-clusterissuer.yaml
    Set-K8sSecret -Name "hetzner-secret" -Namespace "cert-manager" -StringData @{ "api-token" = $hetznerToken }
}

$netbirdKey = Read-OptionalSecret "NetBird Management API personal access token"
if ($netbirdKey) { Set-VaultKV -Path "netbird" -Data @{ "api_key" = $netbirdKey } }

Write-Warn2 "For the next three, run scripts/postgresql/db_create.sh <dbname> (and user_create.sh) on docker01 first - it prints a generated password."

$harborDbUser = Read-Host "Harbor external DB username (blank to skip)"
if ($harborDbUser) {
    $harborDbPass = Read-OptionalSecret "Harbor external DB password"
    Set-VaultKV -Path "harbor" -Data @{ "database.username" = $harborDbUser; "database.password" = $harborDbPass }
}

$kcDbUser = Read-Host "Keycloak external DB username (blank to skip)"
if ($kcDbUser) {
    $kcDbPass = Read-OptionalSecret "Keycloak external DB password"
    Set-VaultKV -Path "keycloak" -Data @{ "postgresql.username" = $kcDbUser; "postgresql.password" = $kcDbPass }
}

$microcksDbUser = Read-Host "Microcks MongoDB username (blank to skip)"
if ($microcksDbUser) {
    $microcksDbPass = Read-OptionalSecret "Microcks MongoDB password"
    Set-VaultKV -Path "microcks" -Data @{ "username" = $microcksDbUser; "password" = $microcksDbPass }
}

# ── 3. Vault backup CronJob (reads these via Kubernetes auth at runtime,
#      not AVP - see kubernetes/backup/kube-vault-backup.yaml) ─────────────
Write-Step "Vault backup (K8s CronJob) - leave blank to skip"

$resticPassword = Read-OptionalSecret "Restic repository password for the vault_pb backup repo"
$rcloneConfPath = Read-Host "Path to an rclone.conf containing the pCloud remote (blank to skip)"
if ($resticPassword -or $rcloneConfPath) {
    $backupData = @{}
    if ($resticPassword) { $backupData["restic_password"] = $resticPassword }
    if ($rcloneConfPath) {
        if (Test-Path $rcloneConfPath) {
            $backupData["rclone_conf"] = Get-Content $rcloneConfPath -Raw
        } else {
            Write-Warn2 "File not found: $rcloneConfPath - skipping rclone_conf."
        }
    }
    Set-VaultKV -Path "vault-backup" -Engine "backup" -Data $backupData
}

Write-Step "Done"
Write-Ok "All generated/provided values are in Vault - nothing was printed to the console or saved to disk."
