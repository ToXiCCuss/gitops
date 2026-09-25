<#
.SYNOPSIS
    Builds the kubeconfig for the Jenkins ServiceAccount jenkins/helm-deployer and stores
    it (Base64, as cicd-library's HelmInstallStep expects) in Vault as
    jenkins/data/jenkins#KUBECONFIG.

.DESCRIPTION
    - Reads the ServiceAccount token and the cluster CA from the Secret
      helm-deployer-token (kubernetes/cicd/kubectl/helm-deployer.yaml) with kubectl.
    - Builds the kubeconfig in memory. The API server address is the in-cluster one,
      because the Jenkins agent pods run inside the cluster.
    - Writes the value into the existing Vault secret and keeps all other keys of it.
      Asks before replacing an existing KUBECONFIG.
    - Nothing is written to disk and the token is never printed (unless you ask for
      -PrintOnly, which prints the Base64 value to the console).

    Prerequisite: the helm-deployer ServiceAccount + token Secret exist in the cluster
    (ArgoCD app cicd-kubectl has synced) and kubectl points at the cluster.

.PARAMETER VaultAddr
    Vault API address reachable from this machine.

.PARAMETER VaultToken
    A Vault token with write access to jenkins/data/jenkins.

.PARAMETER ApiServer
    API server address as seen from the Jenkins agent pods.

.PARAMETER PrintOnly
    Do not touch Vault; print the Base64 kubeconfig instead.

.EXAMPLE
    .\set-jenkins-kubeconfig.ps1 -VaultAddr https://vault.k8sdev.rjst.de -VaultToken s.xxxxx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VaultAddr,
    [Parameter(Mandatory)][string]$VaultToken,
    [string]$Namespace = "jenkins",
    [string]$ServiceAccount = "helm-deployer",
    [string]$TokenSecret = "helm-deployer-token",
    [string]$ApiServer = "https://kubernetes.default.svc",
    [string]$ClusterName = "k8sdev",
    [string]$Engine = "jenkins",
    [string]$Path = "jenkins",
    [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"
$Headers = @{ "X-Vault-Token" = $VaultToken }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# -- 1. token + CA from the cluster ---------------------------------------------------
Write-Step "Reading the ServiceAccount token from $Namespace/$TokenSecret"
$json = kubectl get secret $TokenSecret -n $Namespace -o json
if ($LASTEXITCODE -ne 0 -or -not $json) {
    throw "Secret $Namespace/$TokenSecret not found. Has ArgoCD synced kubernetes/cicd/kubectl/helm-deployer.yaml (app cicd-kubectl)?"
}
$secret = ($json -join "`n") | ConvertFrom-Json
if (-not $secret.data.token -or -not $secret.data.'ca.crt') {
    throw "The token is not populated yet - wait a few seconds after the Secret was created and run again."
}
$token = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.token))
$caB64 = $secret.data.'ca.crt'   # already Base64 of the PEM = certificate-authority-data
Write-Ok "Token and cluster CA found."

# -- 2. kubeconfig in memory ---------------------------------------------------------
$kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
  - name: $ClusterName
    cluster:
      server: $ApiServer
      certificate-authority-data: $caB64
users:
  - name: $ServiceAccount
    user:
      token: $token
contexts:
  - name: $ServiceAccount@$ClusterName
    context:
      cluster: $ClusterName
      user: $ServiceAccount
current-context: $ServiceAccount@$ClusterName
"@
$kubeconfigB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($kubeconfig))
$token = $null; $kubeconfig = $null

if ($PrintOnly) {
    Write-Step "Base64 kubeconfig (put it into jenkins/data/jenkins#KUBECONFIG yourself)"
    Write-Host $kubeconfigB64
    return
}

# -- 3. into Vault, keeping the other keys ---------------------------------------------
Write-Step "Writing $Engine/data/$Path#KUBECONFIG"
$existing = @{}
try {
    $resp = Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Get -Headers $Headers
    if ($resp.data.data) {
        foreach ($p in $resp.data.data.PSObject.Properties) { $existing[$p.Name] = $p.Value }
    }
} catch {
    Write-Warn2 "$Engine/data/$Path does not exist yet - creating it."
}
if ($existing.ContainsKey("KUBECONFIG")) {
    $confirm = Read-Host "  $Engine/data/$Path#KUBECONFIG already has a value. Overwrite? [y/N]"
    if ($confirm -notmatch '^[yY]') { Write-Warn2 "Left unchanged."; return }
}
$existing["KUBECONFIG"] = $kubeconfigB64
$body = @{ data = $existing } | ConvertTo-Json
Invoke-RestMethod -Uri "$VaultAddr/v1/$Engine/data/$Path" -Method Post -Headers $Headers -Body $body -ContentType "application/json" | Out-Null
Write-Ok "$Engine/data/$Path updated (KUBECONFIG; other keys kept: $((@($existing.Keys) | Where-Object { $_ -ne 'KUBECONFIG' }) -join ', '))"

Write-Step "Done"
Write-Ok "Jenkins agents now deploy as $Namespace/$ServiceAccount, not as an admin."
