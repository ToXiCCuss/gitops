<#
.SYNOPSIS
    Puts the private key of the Jenkins GitHub App into Vault as
    argocd/data/jenkins#github_app_private_key.

.DESCRIPTION
    - Reads the .pem file that GitHub offers for download (Generate a private key in the
      settings of the GitHub App) and converts it to the unencrypted PKCS#8 PEM that Jenkins
      needs, with openssl. A key that is already PKCS#8 is taken as it is.
    - Writes the value into the existing Vault secret and keeps all other keys of it
      (for example password). Asks before replacing an existing key.
    - The converted key stays in memory and is never printed. -DeletePem removes the
      downloaded file afterwards.
    - ArgoCD then renders the Secret jenkins/jenkins-github-app from Vault
      (kubernetes/secrets/jenkins-github-app.yaml). A running Jenkins does not notice a changed
      Secret, -RestartJenkins restarts it.

    Prerequisite: openssl (comes with Git for Windows) and a Vault token with write access to
    argocd/data/jenkins. -RestartJenkins also needs kubectl pointing at the cluster.

.PARAMETER VaultAddr
    Vault API address reachable from this machine.

.PARAMETER VaultToken
    A Vault token with write access to argocd/data/jenkins.

.PARAMETER PemPath
    The private key file downloaded from GitHub.

.PARAMETER DeletePem
    Delete the downloaded file after it is in Vault.

.PARAMETER RestartJenkins
    Restart the Jenkins StatefulSet afterwards, so that it reads the new key.

.EXAMPLE
    .\set-jenkins-github-app-key.ps1 -VaultAddr https://vault.k8sdev.rjst.de -VaultToken s.xxxxx -PemPath .\my-app.private-key.pem -DeletePem -RestartJenkins
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultAddr,
    [Parameter(Mandatory)][string]$VaultToken,
    [Parameter(Mandatory)][string]$PemPath,
    [string]$Engine = "argocd",
    [string]$Path = "jenkins",
    [string]$KeyName = "github_app_private_key",
    [string]$Namespace = "jenkins",
    [string]$StatefulSet = "jenkins",
    [switch]$DeletePem,
    [switch]$RestartJenkins
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

function Find-OpenSsl {
    $found = Get-Command openssl -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    foreach ($candidate in @("$env:ProgramFiles\Git\usr\bin\openssl.exe", "$env:ProgramFiles\Git\mingw64\bin\openssl.exe")) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "openssl not found. It comes with Git for Windows (C:\Program Files\Git\usr\bin), put it into the PATH."
}

# -- 1. read and convert the key -------------------------------------------------------
Write-Step "Reading $PemPath"
if (-not (Test-Path $PemPath)) { throw "File not found: $PemPath" }
$pem = (Get-Content -Raw -Path $PemPath).Trim()

if ($pem -match "ENCRYPTED") {
    throw "The key is encrypted. GitHub keys are not, check that this is the file GitHub gave you."
} elseif ($pem -match "-----BEGIN PRIVATE KEY-----") {
    Write-Ok "Already PKCS#8, no conversion needed."
    $converted = $pem
} elseif ($pem -match "-----BEGIN RSA PRIVATE KEY-----") {
    $openssl = Find-OpenSsl
    $lines = & $openssl pkcs8 -topk8 -inform PEM -outform PEM -nocrypt -in $PemPath
    if ($LASTEXITCODE -ne 0 -or -not $lines) { throw "openssl could not convert the key." }
    $converted = ($lines -join "`n").Trim()
    Write-Ok "Converted from PKCS#1 to PKCS#8."
} else {
    throw "This does not look like a private key PEM (expected BEGIN RSA PRIVATE KEY or BEGIN PRIVATE KEY)."
}
if ($converted -notmatch "^-----BEGIN PRIVATE KEY-----") { throw "The converted key has an unexpected format." }
$converted = $converted + "`n"
$pem = $null

# -- 2. into Vault, keeping the other keys ------------------------------------------------
Write-Step "Writing $Engine/data/$Path#$KeyName"
$existing = @{}
try {
    $resp = Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Get -Headers $Headers
    if ($resp.data.data) {
        foreach ($p in $resp.data.data.PSObject.Properties) { $existing[$p.Name] = $p.Value }
    }
} catch {
    Write-Warn2 "$Engine/data/$Path does not exist yet - creating it."
}
if ($existing.ContainsKey($KeyName)) {
    $confirm = Read-Host "  $Engine/data/$Path#$KeyName already has a value. Overwrite? [y/N]"
    if ($confirm -notmatch '^[yY]') { Write-Warn2 "Left unchanged."; return }
}
$existing[$KeyName] = $converted
$body = @{ data = $existing } | ConvertTo-Json
Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
Write-Ok "$Engine/data/$Path updated ($KeyName; other keys kept: $((@($existing.Keys) | Where-Object { $_ -ne $KeyName }) -join ', '))"
$converted = $null; $body = $null

# -- 3. cleanup and restart -------------------------------------------------------------
if ($DeletePem) {
    Remove-Item -Path $PemPath -Force
    Write-Ok "Deleted $PemPath"
}
if ($RestartJenkins) {
    Write-Step "Restarting statefulset/$StatefulSet in $Namespace"
    kubectl -n $Namespace rollout restart statefulset $StatefulSet
    if ($LASTEXITCODE -ne 0) { throw "kubectl could not restart the StatefulSet. Restart Jenkins by hand." }
}

Write-Step "Done"
Write-Ok "ArgoCD renders the Secret $Namespace/jenkins-github-app from Vault, Jenkins reads it as the credential github-app."
