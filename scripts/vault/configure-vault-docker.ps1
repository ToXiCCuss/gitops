<#
.SYNOPSIS
    Vault-side preparation for the secrets of the Docker projects on the Docker host
    (scripts/docker/deploy.sh): KV v2 engine `docker`, read-only policy `docker`,
    AppRole auth and the role `docker01`.

.DESCRIPTION
    deploy.sh logs in with the AppRole before it starts a project listed in VAULT_PROJECTS,
    reads docker/<project> and passes the keys to Compose in a file on a tmpfs.

    The script is idempotent. It never creates a secret_id on its own: that needs -NewSecretId.
    With -NewSecretId it creates one, destroys all other secret_ids of the role (there is exactly
    one valid secret_id afterwards) and prints it once. It is not saved anywhere. Put it on the
    Docker host as /etc/gitops/secret_id (mode 600), the role_id as /etc/gitops/role_id.

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token that may write sys/auth, sys/mounts, sys/policy and auth/approle/*
    (e.g. the root token from init-vault.ps1).

.PARAMETER AllowedCidr
    Addresses the AppRole may be used from (secret_id and the tokens it issues are bound to them),
    e.g. the NetBird address of the Docker host as 100.x.y.z/32. Without it a leaked secret_id works
    from anywhere that reaches Vault.

.PARAMETER NewSecretId
    Creates a new secret_id and destroys the older ones.

.EXAMPLE
    .\configure-vault-docker.ps1 -VaultToken <token> -AllowedCidr 100.64.0.10/32 -NewSecretId
#>
[CmdletBinding()]
param(
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [Parameter(Mandatory)][string]$VaultToken,
    [string[]]$AllowedCidr = @(),
    [switch]$NewSecretId
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }
$Engine = "docker"
$PolicyName = "docker"
$RoleName = "docker01"
$TokenTtl = "5m"
$TokenMaxTtl = "10m"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Invoke-Vault {
    param([string]$Method, [string]$Path, $Body = $null)
    $arguments = @{ Uri = "$VaultAddr/v1/$Path"; Method = $Method; Headers = $Headers }
    if ($null -ne $Body) {
        $arguments.Body = $Body | ConvertTo-Json -Depth 5
        $arguments.ContentType = "application/json"
    }
    Invoke-RestMethod @arguments
}

# ── 1. AppRole auth method ──────────────────────────────────────────────────
Write-Step "Enabling the approle auth method (skipped if already enabled)"
$authMounts = Invoke-Vault -Method Get -Path "sys/auth"
if ($authMounts.PSObject.Properties.Name -contains "approle/") {
    Write-Ok "Already enabled."
} else {
    Invoke-Vault -Method Post -Path "sys/auth/approle" -Body @{ type = "approle" } | Out-Null
    Write-Ok "Enabled."
}

# ── 2. KV v2 engine ─────────────────────────────────────────────────────────
Write-Step "Ensuring the KV v2 engine $Engine/ exists"
$mounts = Invoke-Vault -Method Get -Path "sys/mounts"
$mountNames = @($mounts.PSObject.Properties.Name)
if ($mounts.data) { $mountNames += @($mounts.data.PSObject.Properties.Name) }
if ($mountNames -contains "$Engine/") {
    Write-Ok "$Engine/ already mounted."
} else {
    Invoke-Vault -Method Post -Path "sys/mounts/$Engine" -Body @{ type = "kv-v2" } | Out-Null
    Write-Ok "$Engine/ mounted (kv-v2)."
}

# ── 3. Policy: read only ────────────────────────────────────────────────────
Write-Step "Writing the policy $PolicyName"
$policy = @"
path "$Engine/data/*" {
  capabilities = ["read"]
}
"@
Invoke-Vault -Method Put -Path "sys/policy/$PolicyName" -Body @{ policy = $policy } | Out-Null
Write-Ok "Policy '$PolicyName' written (read on $Engine/data/*)."

# ── 4. AppRole ──────────────────────────────────────────────────────────────
Write-Step "Writing the AppRole $RoleName"
$role = @{
    token_policies = @($PolicyName)
    token_ttl      = $TokenTtl
    token_max_ttl  = $TokenMaxTtl
    secret_id_ttl  = "0"
}
if ($AllowedCidr.Count -gt 0) {
    $role.token_bound_cidrs = @($AllowedCidr)
    $role.secret_id_bound_cidrs = @($AllowedCidr)
    Write-Ok "Bound to: $($AllowedCidr -join ', ')"
} else {
    Write-Warn2 "No -AllowedCidr: the secret_id works from every address that reaches Vault."
}
Invoke-Vault -Method Post -Path "auth/approle/role/$RoleName" -Body $role | Out-Null
Write-Ok "Role '$RoleName' written (tokens live $TokenTtl, max $TokenMaxTtl)."

$roleId = (Invoke-Vault -Method Get -Path "auth/approle/role/$RoleName/role-id").data.role_id

# ── 5. secret_id (only on request) ──────────────────────────────────────────
if ($NewSecretId) {
    Write-Step "Creating a new secret_id and destroying the older ones"
    $created = (Invoke-Vault -Method Post -Path "auth/approle/role/$RoleName/secret-id" -Body @{}).data
    $accessors = (Invoke-Vault -Method Get -Path "auth/approle/role/$RoleName/secret-id?list=true").data.keys
    foreach ($accessor in $accessors | Where-Object { $_ -ne $created.secret_id_accessor }) {
        Invoke-Vault -Method Post -Path "auth/approle/role/$RoleName/secret-id-accessor/destroy" -Body @{ secret_id_accessor = $accessor } | Out-Null
        Write-Ok "Destroyed the older secret_id $accessor."
    }
    Write-Host ""
    Write-Host "    role_id   : $roleId" -ForegroundColor Yellow
    Write-Host "    secret_id : $($created.secret_id)" -ForegroundColor Yellow
    Write-Host ""
    Write-Warn2 "The secret_id is shown once and not saved. On the Docker host as root:"
    Write-Host "      install -d -m 700 /etc/gitops"
    Write-Host "      (umask 077; cat > /etc/gitops/secret_id)   # paste the secret_id, then Ctrl-D"
    Write-Host "      (umask 077; cat > /etc/gitops/role_id)     # paste the role_id, then Ctrl-D"
} else {
    Write-Step "secret_id"
    Write-Ok "Not created (run again with -NewSecretId). role_id: $roleId"
}

Write-Step "Done"
Write-Ok "Engine $Engine/, policy '$PolicyName' and AppRole '$RoleName' are in place."
Write-Warn2 "Put a project's secrets into $Engine/<project>, e.g. vault kv put $Engine/keycloak KC_DB_PASSWORD=..."
