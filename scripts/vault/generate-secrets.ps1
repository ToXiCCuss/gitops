<#
.SYNOPSIS
    Generates/collects the app secrets listed in README.md and
    writes them into Vault (KV v2), so ArgoCD's AVP plugin can render them.

.DESCRIPTION
    - Freely generatable secrets (Harbor/Jenkins/Grafana/Forgejo admin passwords, the OIDC client secrets of Grafana, Harbor, Jenkins,
      Vault, Forgejo and Leantime, the secret key, internal token and backup restic password of Forgejo,
      the session password and backup restic password of Leantime)
      are generated locally and written to Vault, but never replace a value
      that already exists.
    - External values are prompted for interactively and written to Vault:
      the Hetzner and NetBird API tokens, the docker01 DB credentials for
      Harbor, Forgejo and Leantime. Leave blank to skip a value - existing Vault
      data for that key is left untouched.
    - Safe to re-run: it asks before overwriting a value you provide if it
      already has one.
    - Nothing is written to disk. The raw Secrets that ArgoCD renders from
      these Vault values live in kubernetes/secrets/.

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token with write access to argocd/data/*. Use the root token
    from init-vault.ps1 for a first run, or a scoped token afterwards.

.EXAMPLE
    .\generate-secrets.ps1 -VaultAddr http://127.0.0.1:8200 -VaultToken s.xxxxx
#>
[CmdletBinding()]
param(
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
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
    param([string]$Path, [hashtable]$Data, [string]$Engine = "argocd", [switch]$SkipExisting)
    Confirm-KVEngine -Engine $Engine
    $existing = Get-VaultKV -Path $Path -Engine $Engine
    $merged = @{}
    $changedKeys = @()
    foreach ($k in $existing.Keys) { $merged[$k] = $existing[$k] }
    foreach ($k in $Data.Keys) {
        if ([string]::IsNullOrEmpty($Data[$k])) { continue }  # never write blanks over existing data
        if ($merged.ContainsKey($k) -and $merged[$k] -eq $Data[$k]) { continue }
        if ($SkipExisting -and $merged.ContainsKey($k)) { continue }  # generated values: never replace what's there
        if ($merged.ContainsKey($k)) {
            $confirm = Read-Host "  $Engine/data/$Path#$k already has a value. Overwrite? [y/N]"
            if ($confirm -notmatch '^[yY]') { continue }
        }
        $merged[$k] = $Data[$k]
        $changedKeys += $k
    }
    if ($changedKeys.Count -gt 0) {
        $body = @{ data = $merged } | ConvertTo-Json
        Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
        Write-Ok "$Engine/data/$Path updated ($($changedKeys -join ', '))"
    } else {
        Write-Ok "$Engine/data/$Path unchanged"
    }
}

function Read-OptionalSecret {
    param([string]$Prompt)
    $secure = Read-Host $Prompt -AsSecureString
    if ($secure.Length -eq 0) { return "" }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# ── 1. Freely generatable app passwords ────────────────────────────────────
Write-Step "Generating app-internal admin passwords"
Set-VaultKV -Path "harbor" -Data @{ "admin.password" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "jenkins" -Data @{ "password" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "prometheus" -Data @{ "password" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "prometheus" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "harbor" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "jenkins" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "vault" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
# security.secret_key encrypts the secrets in the Forgejo database: SkipExisting keeps it, a new value would make them unreadable
Set-VaultKV -Path "forgejo" -Data @{ "admin.password" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "forgejo" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "forgejo" -Data @{ "security.secret_key" = (New-RandomSecret -Length 64) } -SkipExisting
Set-VaultKV -Path "forgejo" -Data @{ "security.internal_token" = (New-RandomSecret -Length 64) } -SkipExisting
# Restic password of the repository forgejo/restic (the CronJob forgejo-backup): without it the backup cannot be read
Set-VaultKV -Path "forgejo" -Data @{ "backup.restic_password" = (New-RandomSecret -Length 64) } -SkipExisting
Set-VaultKV -Path "leantime" -Data @{ "oidc.client_secret" = (New-RandomSecret) } -SkipExisting
Set-VaultKV -Path "leantime" -Data @{ "session.password" = (New-RandomSecret -Length 64) } -SkipExisting
# Restic password of the repository leantime/restic (the CronJob leantime-backup): without it the backup cannot be read
Set-VaultKV -Path "leantime" -Data @{ "backup.restic_password" = (New-RandomSecret -Length 64) } -SkipExisting

# ── 2. External values that must match reality - prompt, never generate ───
Write-Step "External values (leave blank to skip / keep existing)"

$hetznerToken = Read-OptionalSecret "Hetzner Cloud API token (DNS read/write, blank to skip)"
if ($hetznerToken) { Set-VaultKV -Path "hetzner" -Data @{ "token" = $hetznerToken } }

$netbirdKey = Read-OptionalSecret "NetBird Management API personal access token (blank to skip)"
if ($netbirdKey) { Set-VaultKV -Path "netbird" -Data @{ "api_key" = $netbirdKey } }

Write-Warn2 "For Harbor, run scripts/postgresql/db_create.sh harbor (and user_create.sh) on docker01 first - it prints a generated password."

$harborDbUser = Read-Host "Harbor external DB username (blank to skip)"
if ($harborDbUser) {
    $harborDbPass = Read-OptionalSecret "Harbor external DB password"
    Set-VaultKV -Path "harbor" -Data @{ "database.username" = $harborDbUser; "database.password" = $harborDbPass }
}

Write-Warn2 "For Forgejo, run scripts/postgresql/db_create.sh forgejo on docker01 first - the password of forgejo_owner is in Vault databases/postgresql/forgejo_owner."

$forgejoDbUser = Read-Host "Forgejo external DB username (blank to skip)"
if ($forgejoDbUser) {
    $forgejoDbPass = Read-OptionalSecret "Forgejo external DB password"
    Set-VaultKV -Path "forgejo" -Data @{ "database.username" = $forgejoDbUser; "database.password" = $forgejoDbPass }
}

Write-Warn2 "For Leantime, run scripts/mariadb/db_create.sh leantime on docker01 first - the password of leantime_owner is in Vault databases/mariadb/leantime_owner."

$leantimeDbUser = Read-Host "Leantime external DB username (blank to skip)"
if ($leantimeDbUser) {
    $leantimeDbPass = Read-OptionalSecret "Leantime external DB password"
    Set-VaultKV -Path "leantime" -Data @{ "database.username" = $leantimeDbUser; "database.password" = $leantimeDbPass }
}

# ── 3. Copies between the KV engines ───────────────────────────────────────
# The AVP plugin may only read argocd/, the Docker host only docker/. The backup of Forgejo needs the keys of the
# RustFS identity forgejo (docker/s3/forgejo, scripts/vault/create-s3-identities.ps1) in the cluster, and the
# nightly check of restic-backup on docker01 needs its restic password.
Write-Step "Copying the Forgejo backup values between argocd/ and docker/"
$forgejoS3 = Get-VaultKV -Path "s3/forgejo" -Engine "docker"
if ($forgejoS3.ContainsKey("access_key")) {
    Set-VaultKV -Path "forgejo" -Data @{ "backup.s3_access_key" = $forgejoS3["access_key"]; "backup.s3_secret_key" = $forgejoS3["secret_key"] }
} else {
    Write-Warn2 "docker/s3/forgejo does not exist yet: run create-s3-identities.ps1 first, then this script again."
}
$forgejo = Get-VaultKV -Path "forgejo"
Set-VaultKV -Path "restic-backup" -Engine "docker" -Data @{ "RESTIC_PASSWORD_FORGEJO" = $forgejo["backup.restic_password"] }

# The same for the backup of Leantime
Write-Step "Copying the Leantime backup values between argocd/ and docker/"
$leantimeS3 = Get-VaultKV -Path "s3/leantime" -Engine "docker"
if ($leantimeS3.ContainsKey("access_key")) {
    Set-VaultKV -Path "leantime" -Data @{ "backup.s3_access_key" = $leantimeS3["access_key"]; "backup.s3_secret_key" = $leantimeS3["secret_key"] }
} else {
    Write-Warn2 "docker/s3/leantime does not exist yet: run create-s3-identities.ps1 first, then this script again."
}
$leantime = Get-VaultKV -Path "leantime"
Set-VaultKV -Path "restic-backup" -Engine "docker" -Data @{ "RESTIC_PASSWORD_LEANTIME" = $leantime["backup.restic_password"] }

Write-Step "Done"
Write-Ok "All generated/provided values are in Vault - nothing was printed to the console or saved to disk."
