<#
.SYNOPSIS
    Generates/collects the app secrets listed in kubernetes/README.adoc and
    writes them into Vault (KV v2), so ArgoCD's AVP plugin can render them.

.DESCRIPTION
    - Freely generatable secrets (Harbor/Jenkins/Grafana admin passwords, the
      self-signed root CA) are generated locally and written straight away.
    - External values that must match something outside this repo (Hetzner
      API token, NetBird PAT, and the docker01 DB credentials for
      Harbor/Keycloak/Microcks) are prompted for interactively. Leave blank
      to skip a value - existing Vault data for that key is left untouched.
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
    param([string]$Path)
    try {
        $resp = Invoke-RestMethod -Uri "$VaultAddr/v1/argocd/data/$Path" -Method Get -Headers $Headers
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

function Set-VaultKV {
    param([string]$Path, [hashtable]$Data)
    $existing = Get-VaultKV -Path $Path
    $merged = @{}
    foreach ($k in $existing.Keys) { $merged[$k] = $existing[$k] }
    foreach ($k in $Data.Keys) {
        if ([string]::IsNullOrEmpty($Data[$k])) { continue }  # never write blanks over existing data
        if ($merged.ContainsKey($k) -and $merged[$k] -eq $Data[$k]) { continue }
        if ($merged.ContainsKey($k)) {
            $confirm = Read-Host "  argocd/data/$Path#$k already has a value. Overwrite? [y/N]"
            if ($confirm -notmatch '^[yY]') { continue }
        }
        $merged[$k] = $Data[$k]
    }
    $body = @{ data = $merged } | ConvertTo-Json
    Invoke-RestMethod -Uri "$VaultAddr/v1/argocd/data/$Path" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
    Write-Ok "argocd/data/$Path updated ($($Data.Keys -join ', '))"
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
Set-VaultKV -Path "harbor" -Data @{ "admin.password" = (New-RandomSecret) }
Set-VaultKV -Path "jenkins" -Data @{ "password" = (New-RandomSecret) }
Set-VaultKV -Path "prometheus" -Data @{ "password" = (New-RandomSecret) }

# ── 2. Self-signed root CA (for the "self-issuer" ClusterIssuer) ──────────
Write-Step "Generating self-signed root CA"
$opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
if ($opensslCmd) {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "rjst-ca-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    & openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes `
        -keyout "$tmp\ca.key" -out "$tmp\ca.crt" `
        -subj "/CN=rjst.de self-signed root CA" 2>&1 | Out-Null
    if (Test-Path "$tmp\ca.crt") {
        $crtB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$tmp\ca.crt"))
        $keyB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$tmp\ca.key"))
        # ca-self-secret uses `data:` (not stringData:), so Vault must hold
        # already-base64-encoded values - see kubernetes/infra/kube-clusterissuer.yaml
        Set-VaultKV -Path "ca" -Data @{ "ca.crt" = $crtB64; "ca.key" = $keyB64 }
    } else {
        Write-Warn2 "openssl failed to generate the CA - skipping, see manual command below."
    }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
} else {
    Write-Warn2 "openssl not found on PATH (ships with Git for Windows). Generate manually, then base64-encode and store at argocd/data/ca#ca.crt / #ca.key:"
    Write-Warn2 '  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout ca.key -out ca.crt -subj "/CN=rjst.de self-signed root CA"'
}

# ── 3. External values that must match reality - prompt, never generate ───
Write-Step "External values (leave blank to skip / keep existing)"

$hetznerToken = Read-OptionalSecret "Hetzner Cloud API token (DNS read/write)"
if ($hetznerToken) { Set-VaultKV -Path "ca" -Data @{ "hetzner.token" = $hetznerToken } }

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

Write-Step "Done"
Write-Ok "All generated/provided values are in Vault - nothing was printed to the console or saved to disk."
