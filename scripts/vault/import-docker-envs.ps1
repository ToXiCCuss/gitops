<#
.SYNOPSIS
    Moves the old override.env files of all Docker projects from the Docker host into Vault in one go.

.DESCRIPTION
    For every project it reads docker/<project>/override.env from the host over SSH and merges it into the
    Vault secret docker/<project> with import-docker-env.ps1 (the S3 keys are left out, deploy.sh takes them from
    the S3 identity; values are never printed). A project whose file is missing or holds no values is reported
    and skipped, the others are still imported. Run it with -DryRun first.

.PARAMETER VaultToken
    A Vault token that may write docker/data/* (e.g. the root token). Not needed with -DryRun.

.PARAMETER Projects
    Default: rustfs, restic-backup, offsite-sync, vault-backup.

.PARAMETER SshTarget
    User and host of the Docker host. Default: root@docker01.

.PARAMETER RepositoryPath
    Checkout of this repository on the Docker host. Default: /root/gitops.

.EXAMPLE
    .\import-docker-envs.ps1 -DryRun
    .\import-docker-envs.ps1 -VaultToken <token>
#>
[CmdletBinding()]
param(
    [string]$VaultToken,
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [string[]]$Projects = @("rustfs", "restic-backup", "offsite-sync", "vault-backup"),
    [string]$SshTarget = "root@docker01",
    [string]$RepositoryPath = "/root/gitops",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$importScript = Join-Path $PSScriptRoot "import-docker-env.ps1"
$skipped = @()

foreach ($project in $Projects) {
    Write-Host "`n==> $project" -ForegroundColor Cyan
    $content = @(ssh -o BatchMode=yes $SshTarget "cat $RepositoryPath/docker/$project/override.env")
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    skipped: no readable $RepositoryPath/docker/$project/override.env on $SshTarget" -ForegroundColor Yellow
        $skipped += $project
        continue
    }
    try {
        $content | & $importScript -Project $project -VaultAddr $VaultAddr -VaultToken $VaultToken -DryRun:$DryRun
    } catch {
        Write-Host "    skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        $skipped += $project
    }
}

Write-Host ""
if ($skipped.Count -gt 0) {
    Write-Host "Skipped: $($skipped -join ', '). Put their secrets into Vault by hand (vault kv put docker/<project> ...)." -ForegroundColor Yellow
}
Write-Host "Done. Next on the Docker host: deploy the projects with scripts/docker/deploy.sh <project>, then delete the old override.env files." -ForegroundColor Green
