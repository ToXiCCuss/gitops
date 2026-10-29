<#
.SYNOPSIS
    Creates the S3 keys of the RustFS identities (docker/rustfs/identities.json) in Vault.

.DESCRIPTION
    For every identity of identities.json the secret docker/s3/<name> (access_key, secret_key) is created
    if it does not exist yet. An existing secret is never changed. The keys are random letters and digits,
    so that they survive the forms of Pelican and the env files of the Compose projects.

    RustFS itself is not touched: scripts/docker/setup-rustfs.sh on the Docker host reads the keys from
    Vault and creates the users and policies. The keys are not printed. Read one when you need it:
    vault kv get docker/s3/pelican

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token that may write docker/data/s3/* (e.g. the root token).

.PARAMETER IdentitiesFile
    Default: docker/rustfs/identities.json of this repository.

.EXAMPLE
    .\create-s3-identities.ps1 -VaultToken <token>
#>
[CmdletBinding()]
param(
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [Parameter(Mandatory)][string]$VaultToken,
    [string]$IdentitiesFile = (Join-Path $PSScriptRoot "..\..\docker\rustfs\identities.json")
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }
$Engine = "docker"
$AccessKeyLength = 20
$SecretKeyLength = 40
$AccessKeyAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$SecretKeyAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
$HttpNotFound = 404

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }

# New-RandomKey: characters of the alphabet from the system random generator. Bytes above the largest
# multiple of the alphabet size are dropped, so that no character is more likely than another.
function New-RandomKey {
    param([int]$Length, [string]$Alphabet)
    $limit = 256 - (256 % $Alphabet.Length)
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 1
    $key = New-Object System.Text.StringBuilder
    while ($key.Length -lt $Length) {
        $generator.GetBytes($buffer)
        if ($buffer[0] -lt $limit) { [void]$key.Append($Alphabet[$buffer[0] % $Alphabet.Length]) }
    }
    $generator.Dispose()
    $key.ToString()
}

function Test-VaultSecret {
    param([string]$Name)
    $exists = $true
    try {
        Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/s3/$Name" -Method Get -Headers $Headers | Out-Null
    } catch {
        if ([int]$_.Exception.Response.StatusCode -eq $HttpNotFound) { $exists = $false } else { throw }
    }
    $exists
}

Write-Step "Reading $IdentitiesFile"
$identities = (Get-Content -Raw -Path $IdentitiesFile | ConvertFrom-Json).identities
Write-Ok "$($identities.Count) identities."

Write-Step "Creating the missing keys in $Engine/s3/<name>"
foreach ($identity in $identities) {
    if (Test-VaultSecret -Name $identity.name) {
        Write-Ok "$($identity.name): exists, unchanged."
        continue
    }
    # cas = 0: Vault writes only if the secret still does not exist
    $body = @{
        options = @{ cas = 0 }
        data    = @{
            access_key = New-RandomKey -Length $AccessKeyLength -Alphabet $AccessKeyAlphabet
            secret_key = New-RandomKey -Length $SecretKeyLength -Alphabet $SecretKeyAlphabet
        }
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/s3/$($identity.name)" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
    Write-Ok "$($identity.name): created."
}

Write-Step "Done"
Write-Ok "Next on the Docker host: sudo scripts/docker/setup-rustfs.sh creates the users and policies in RustFS."
