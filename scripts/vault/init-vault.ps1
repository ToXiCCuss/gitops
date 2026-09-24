<#
.SYNOPSIS
    One-time Vault initialization: runs `vault operator init`, unseals Vault,
    and seeds the vault-unsealer-config Secret directly via kubectl (bypassing
    AVP, since Vault can't read its own unseal keys from itself before it's
    unsealed the first time - see kubernetes/README.adoc).

.DESCRIPTION
    Run this exactly once, right after the "infra" domain has deployed a
    fresh, uninitialized Vault pod. Re-running against an already-initialized
    Vault is refused by Vault itself and this script will just exit.

.PARAMETER VaultAddr
    Vault API address reachable from this machine (e.g. via
    `kubectl port-forward -n vault svc/vault 8200:8200`).

.PARAMETER Namespace
    Kubernetes namespace Vault runs in. Default: vault.

.EXAMPLE
    .\init-vault.ps1 -VaultAddr http://127.0.0.1:8200
#>
[CmdletBinding()]
param(
    [string]$VaultAddr = "http://127.0.0.1:8200",
    [string]$Namespace = "vault",
    [int]$SecretShares = 5,
    [int]$SecretThreshold = 3
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

Write-Step "Checking Vault status at $VaultAddr"
try {
    $health = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/health" -Method Get
    # 200 here means already initialized, unsealed and active
    Write-Warn2 "Vault is already initialized. Refusing to run - this script is for a fresh Vault only."
    exit 1
} catch {
    $statusCode = $null
    if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }
    if ($statusCode -eq 501) {
        Write-Ok "Vault is uninitialized, proceeding."
    } elseif ($statusCode -eq 503) {
        Write-Warn2 "Vault is already initialized but sealed. Refusing to run - this script is for a fresh Vault only."
        exit 1
    } else {
        Write-Host "    Could not reach Vault at $VaultAddr (status: $statusCode). $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Step "Initializing Vault ($SecretShares shares, threshold $SecretThreshold)"
$initBody = @{
    secret_shares    = $SecretShares
    secret_threshold = $SecretThreshold
} | ConvertTo-Json
$init = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/init" -Method Put -Body $initBody -ContentType "application/json"

$keys = $init.keys
$rootToken = $init.root_token

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outFile = Join-Path $PSScriptRoot "vault-init-$stamp.txt"
@"
VAULT INITIALIZATION - $stamp
==============================================================
Root Token:  $rootToken

Unseal Keys (need $SecretThreshold of $SecretShares to unseal):
$(($keys | ForEach-Object { "  - $_" }) -join "`n")
==============================================================
KEEP THIS FILE OFFLINE (password manager / printed safe).
Delete it from this machine once safely stored elsewhere.
"@ | Out-File -FilePath $outFile -Encoding utf8

Write-Ok "Root token and unseal keys written to: $outFile"
Write-Warn2 "This is the ONLY time Vault will ever show you these. Save them now."
Read-Host "Press Enter once you've backed up $outFile somewhere safe" | Out-Null

Write-Step "Unsealing Vault ($SecretThreshold of $SecretShares keys)"
for ($i = 0; $i -lt $SecretThreshold; $i++) {
    $body = @{ key = $keys[$i] } | ConvertTo-Json
    $result = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/unseal" -Method Put -Body $body -ContentType "application/json"
    Write-Ok "Unseal progress: $($result.progress)/$($result.t)"
}
if ($result.sealed) {
    Write-Host "Vault is still sealed - something went wrong." -ForegroundColor Red
    exit 1
}
Write-Ok "Vault is unsealed."

Write-Step "Writing the vault-unsealer-config Secret manifest (bypasses AVP for this one bootstrap secret)"
$keyLines = for ($i = 0; $i -lt $keys.Count; $i++) { "  unsealKey$($i+1): $($keys[$i])" }
$secretYaml = @"
apiVersion: v1
kind: Secret
metadata:
  name: vault-unsealer-config
  namespace: $Namespace
  labels:
    vault-unsealer.bakito.net/stateful-set: vault
type: Opaque
stringData:
$($keyLines -join "`n")
"@
$yamlFile = Join-Path $PSScriptRoot "vault-unsealer-config-$stamp.yaml"
$secretYaml | Out-File -FilePath $yamlFile -Encoding utf8
Write-Ok "Wrote the Secret manifest to $yamlFile"
Write-Warn2 "Review it, then apply it yourself:  kubectl apply -f `"$yamlFile`""

Write-Step "Done"
Write-Warn2 "Next: run generate-secrets.ps1 with -VaultToken `"$rootToken`" (or a less-privileged token you create from it) to seed the remaining app secrets."
Write-Warn2 "Consider revoking/rotating the root token afterwards and using a scoped policy instead."
