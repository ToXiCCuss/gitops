<#
.SYNOPSIS
    Login to Vault with Keycloak (OIDC): the auth method, two policies and two external groups.

.DESCRIPTION
    The roles come from the Keycloak client "vault" (docker/keycloak-config/realms/rjst.yaml) and arrive in the claim
    "roles". Each role is an external Vault group with one policy:

      admin      policy keycloak_admin      everything
      developer  policy keycloak_developer  read and write the secrets in dev/ and prod/ (no delete)

    A user without one of the roles is refused at the login (bound_claims). The root token and every other way to
    log in stay as they are, OIDC is added next to them. Nothing is restarted. The script can be run again, it
    overwrites what it wrote before.

    The client secret is read from Vault (argocd/data/vault#oidc.client_secret, written by generate-secrets.ps1).
    The same value must be the secret of the client in Keycloak (VAULT_CLIENT_SECRET of docker/keycloak-config).

    Vault reads the OIDC discovery of Keycloak when the configuration is written, so the Vault pod has to reach
    OidcDiscoveryUrl. If that fails, check the DNS of the cluster for auth.proxy.rjst.de (NetBird resolver).

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token with sufficient rights (sys/auth, sys/policy, identity/*, auth/oidc/*), the root token for example.

.PARAMETER OidcDiscoveryUrl
    The issuer of the Keycloak realm. Default: https://auth.proxy.rjst.de/realms/rjst.

.PARAMETER ClientId
    The Keycloak client. Default: vault.

.EXAMPLE
    .\configure-vault-oidc.ps1 -VaultToken s.xxxxx
#>
[CmdletBinding()]
param(
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [Parameter(Mandatory)][string]$VaultToken,
    [string]$OidcDiscoveryUrl = "https://auth.proxy.rjst.de/realms/rjst",
    [string]$ClientId = "vault"
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }
$ClientSecretPath = "argocd/data/vault"
$ClientSecretKey = "oidc.client_secret"
$MountPath = "oidc"
$DefaultRole = "default"
$TokenTtl = "8h"
$RedirectUris = @(
    "$VaultAddr/ui/vault/auth/$MountPath/oidc/callback",
    "http://localhost:8250/oidc/callback"
)

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

function Invoke-Vault {
    param([string]$Method, [string]$Path, $Body = $null)
    $arguments = @{ Uri = "$VaultAddr/v1/$Path"; Method = $Method; Headers = $Headers }
    if ($null -ne $Body) {
        $arguments.Body = ($Body | ConvertTo-Json -Depth 5)
        $arguments.ContentType = "application/json"
    }
    Invoke-RestMethod @arguments
}

# ── 1. The client secret from Vault ─────────────────────────────────────────
Write-Step "Reading the client secret from $ClientSecretPath"
$secretResponse = Invoke-Vault -Method Get -Path $ClientSecretPath
$clientSecret = $secretResponse.data.data.$ClientSecretKey
if ([string]::IsNullOrEmpty($clientSecret)) {
    Write-Host "No $ClientSecretKey in $ClientSecretPath. Run generate-secrets.ps1 first." -ForegroundColor Red
    exit 1
}
Write-Ok "Found (not shown)."

# ── 2. The auth method ──────────────────────────────────────────────────────
Write-Step "Enabling the auth method $MountPath (skipped if already enabled)"
$authMounts = Invoke-Vault -Method Get -Path "sys/auth"
if ($authMounts.PSObject.Properties.Name -contains "$MountPath/") {
    Write-Ok "Already enabled."
} else {
    Invoke-Vault -Method Post -Path "sys/auth/$MountPath" -Body @{ type = "oidc" } | Out-Null
    Write-Ok "Enabled."
}
$mountAccessor = (Invoke-Vault -Method Get -Path "sys/auth").data."$MountPath/".accessor
if ([string]::IsNullOrEmpty($mountAccessor)) {
    $mountAccessor = (Invoke-Vault -Method Get -Path "sys/auth")."$MountPath/".accessor
}

# ── 3. The policies ─────────────────────────────────────────────────────────
function Set-VaultPolicy {
    param([string]$Name, [string]$Hcl)
    Invoke-Vault -Method Put -Path "sys/policy/$Name" -Body @{ policy = $Hcl } | Out-Null
    Write-Ok "Policy '$Name' written."
}

Write-Step "Policies"
Set-VaultPolicy -Name "keycloak_admin" -Hcl @'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
'@
Set-VaultPolicy -Name "keycloak_developer" -Hcl @'
path "dev/data/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "dev/metadata/*" {
  capabilities = ["read", "list"]
}
path "prod/data/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "prod/metadata/*" {
  capabilities = ["read", "list"]
}
'@

# ── 4. The OIDC configuration and the role of the login ────────────────────
Write-Step "Writing the OIDC configuration (Vault reads the discovery of $OidcDiscoveryUrl now)"
Invoke-Vault -Method Post -Path "auth/$MountPath/config" -Body @{
    oidc_discovery_url = $OidcDiscoveryUrl
    oidc_client_id     = $ClientId
    oidc_client_secret = $clientSecret
    default_role       = $DefaultRole
} | Out-Null
Write-Ok "auth/$MountPath/config written."

Write-Step "Writing the role '$DefaultRole' of the login"
Invoke-Vault -Method Post -Path "auth/$MountPath/role/$DefaultRole" -Body @{
    role_type             = "oidc"
    user_claim            = "preferred_username"
    groups_claim          = "roles"
    oidc_scopes           = @("openid", "profile", "email")
    allowed_redirect_uris = $RedirectUris
    bound_claims          = @{ roles = @("admin", "developer") }
    token_ttl             = $TokenTtl
} | Out-Null
Write-Ok "Role '$DefaultRole' written (only users with the role admin or developer get in)."

# ── 5. The external groups, one per Keycloak role ───────────────────────────
function Set-ExternalGroup {
    param([string]$Name, [string]$Policy)
    Invoke-Vault -Method Post -Path "identity/group/name/$Name" -Body @{
        type     = "external"
        policies = @($Policy)
    } | Out-Null
    $group = (Invoke-Vault -Method Get -Path "identity/group/name/$Name").data
    if ($group.alias -and $group.alias.id) {
        Write-Ok "Group '$Name' with policy '$Policy' written (alias exists)."
    } else {
        Invoke-Vault -Method Post -Path "identity/group-alias" -Body @{
            name           = $Name
            mount_accessor = $mountAccessor
            canonical_id   = $group.id
        } | Out-Null
        Write-Ok "Group '$Name' with policy '$Policy' written, alias created."
    }
}

Write-Step "External groups"
Set-ExternalGroup -Name "admin" -Policy "keycloak_admin"
Set-ExternalGroup -Name "developer" -Policy "keycloak_developer"

Write-Step "Done"
Write-Ok "Log in in the UI with the method OIDC (role field empty), or: vault login -method=oidc"
