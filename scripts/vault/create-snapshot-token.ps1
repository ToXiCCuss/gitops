<#
.SYNOPSIS
    Creates the policy vault_snapshot and a periodic token for the Vault backup
    (docker/vault-backup on the Docker host).

.DESCRIPTION
    The policy only allows reading the Raft snapshot. The token is periodic
    (never expires as long as it is renewed within the period; the backup renews
    it on every run) and an orphan (not bound to the token that created it).

    The token is printed once and not saved anywhere. Put it into the Arcane
    project environment of vault-backup as VAULT_TOKEN.

.PARAMETER VaultAddr
    Vault API address reachable from this machine.

.PARAMETER VaultToken
    A Vault token that may write policies and create tokens (e.g. the root token
    from init-vault.ps1).

.PARAMETER Period
    Renewal period of the token. Default: 768h (32 days).

.EXAMPLE
    .\scripts\vault\create-snapshot-token.ps1 -VaultAddr http://127.0.0.1:8200 -VaultToken <token>
#>
param(
    [Parameter(Mandatory = $true)][string]$VaultAddr,
    [Parameter(Mandatory = $true)][string]$VaultToken,
    [string]$Period = "768h"
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

Write-Step "Writing the policy vault_snapshot"
$policy = @'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
'@
Invoke-RestMethod -Uri "$VaultAddr/v1/sys/policies/acl/vault_snapshot" -Method Put -Headers $Headers -Body (@{ policy = $policy } | ConvertTo-Json) -ContentType "application/json" | Out-Null
Write-Ok "Policy vault_snapshot written."

Write-Step "Creating the periodic token (period $Period)"
$body = @{
    policies     = @("vault_snapshot")
    period       = $Period
    no_parent    = $true
    renewable    = $true
    display_name = "vault-snapshot-backup"
} | ConvertTo-Json
$result = Invoke-RestMethod -Uri "$VaultAddr/v1/auth/token/create" -Method Post -Headers $Headers -Body $body -ContentType "application/json"
$token = $result.auth.client_token

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host "  VAULT_TOKEN for docker/vault-backup:  $token" -ForegroundColor Yellow
Write-Host "==============================================================" -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter once you've put it into the Arcane environment" | Out-Null

Write-Step "Done"
Write-Ok "The token can only read sys/storage/raft/snapshot and is renewed by every backup run."
