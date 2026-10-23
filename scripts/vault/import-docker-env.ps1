<#
.SYNOPSIS
    Moves the variables of an old override.env of a Docker project into the Vault secret docker/<Project>.

.DESCRIPTION
    Reads NAME=value lines from the pipeline (for example from the Docker host over SSH), skips comments, blank
    lines and the S3 keys (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY: deploy.sh takes them from docker/s3/<identity>),
    and merges the rest into docker/<Project> (existing keys of the secret that are not in the file stay).
    It prints the names of the keys, never the values.

.PARAMETER Project
    Name of the project, the secret is docker/<Project>.

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token that may write docker/data/* (e.g. the root token). Not needed with -DryRun.

.PARAMETER ExcludedNames
    Variables that are not imported. Default: the S3 keys.

.PARAMETER DryRun
    Only prints the names that would be imported.

.EXAMPLE
    ssh root@docker01 "cat /root/gitops/docker/rustfs/override.env" | .\import-docker-env.ps1 -Project rustfs -VaultToken <token>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Project,
    [string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [string]$VaultToken,
    [string[]]$ExcludedNames = @("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"),
    [switch]$DryRun,
    [Parameter(ValueFromPipeline)][string]$Line
)

begin {
    $ErrorActionPreference = "Stop"
    $Engine = "docker"
    $HttpNotFound = 404
    $variables = [ordered]@{}
    $variableLine = '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$'

    # Strip one pair of surrounding quotes, as an env file allows them
    function Remove-Quotes([string]$value) {
        $value = $value.Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $value
    }
}

process {
    if ($Line -match $variableLine -and $ExcludedNames -notcontains $Matches[1]) {
        $variables[$Matches[1]] = Remove-Quotes $Matches[2]
    }
}

end {
    $names = @($variables.Keys | Where-Object { $variables[$_] -ne "" })
    if ($names.Count -eq 0) { throw "No variable with a value found on the input (is the input empty?)." }
    Write-Host "Keys for $Engine/${Project}: $($names -join ', ')" -ForegroundColor Cyan
    if ($DryRun) { return }
    if (-not $VaultToken) { throw "-VaultToken is required (or use -DryRun)." }

    $data = @{}
    foreach ($name in $names) { $data[$name] = $variables[$name] }
    $headers = @{ "X-Vault-Token" = $VaultToken }
    $uri = "$VaultAddr/v1/$Engine/data/$Project"
    try {
        # PATCH merges into an existing secret
        Invoke-RestMethod -Uri $uri -Method Patch -Headers $headers -Body (@{ data = $data } | ConvertTo-Json -Depth 5) -ContentType "application/merge-patch+json" | Out-Null
        Write-Host "Merged into $Engine/$Project." -ForegroundColor Green
    } catch {
        if ([int]$_.Exception.Response.StatusCode -ne $HttpNotFound) { throw }
        Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body (@{ data = $data } | ConvertTo-Json -Depth 5) -ContentType "application/json" | Out-Null
        Write-Host "Created $Engine/$Project." -ForegroundColor Green
    }
}
