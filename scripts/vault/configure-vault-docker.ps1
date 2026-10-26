<#
.SYNOPSIS
    Vault-side preparation for the secrets of the Docker projects on the Docker host
    (scripts/docker/deploy.sh): KV v2 engine `docker`, read-only policy `docker`,
    AppRole auth and the role `docker01`.

.DESCRIPTION
    deploy.sh logs in with the AppRole before it starts a project listed in VAULT_PROJECTS,
    reads docker/<project> and passes the keys to Compose in a file on a tmpfs.

    The script is idempotent and reports per resource whether it was Created, Updated or Unchanged.
    It never creates a secret_id on its own: that needs -NewSecretId. With -NewSecretId it creates one
    and destroys all other secret_ids of the role (exactly one valid secret_id is left).

    With -DockerHost the script puts the role_id and the secret_id on that host over SSH as
    /etc/gitops/role_id and /etc/gitops/secret_id (mode 600, directory 700). The values travel through
    the stdin of ssh and are not shown. The older secret_ids are destroyed only after both files are on
    the host, so a failed SSH login leaves the working one valid. Without -DockerHost the secret_id is
    shown once and you put the files there yourself.

.PARAMETER VaultAddr
    Vault API address reachable from this machine. Default: https://vault.k8sdev.rjst.de.

.PARAMETER VaultToken
    A Vault token that may write sys/auth, sys/mounts, sys/policies and auth/approle/*
    (e.g. the root token from init-vault.ps1), as a SecureString.

.PARAMETER AllowedCidr
    Addresses the AppRole may be used from (secret_id and the tokens it issues are bound to them).
    Leave it empty for the setup of this repo: Vault runs in the cluster and sees the address of a pod
    of the cluster network (10.42.x.x) instead of the NetBird address of the Docker host, so a binding to
    the host fails with "source address unauthorized by CIDR restrictions". Without it a leaked secret_id
    works from anywhere that reaches Vault, which the short token lifetime and the rotation by
    -NewSecretId make up for.

.PARAMETER NewSecretId
    Creates a new secret_id and destroys the older ones.

.PARAMETER DockerHost
    Host name or address of the Docker host. Needs -NewSecretId. The credential files are written there
    over SSH (key or password login of -SshUser, the host key must be known).

.PARAMETER SshUser
    User for the SSH login, it has to be allowed to write /etc/gitops. Default: root.

.PARAMETER SshArgument
    Further ssh options, e.g. -p 2222 or -i <key file>.

.EXAMPLE
    .\configure-vault-docker.ps1 -VaultToken (Read-Host -AsSecureString "Vault token") -WhatIf

.EXAMPLE
    .\configure-vault-docker.ps1 -VaultToken (Read-Host -AsSecureString "Vault token") -NewSecretId -DockerHost docker01.vpn.rjst.de
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()][string]$VaultAddr = "https://vault.k8sdev.rjst.de",
    [Parameter(Mandatory)][securestring]$VaultToken,
    [string[]]$AllowedCidr = @(),
    [switch]$NewSecretId,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$DockerHost,
    [ValidatePattern('^[a-z_][a-z0-9_-]*$')][string]$SshUser = "root",
    [string[]]$SshArgument = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($DockerHost -and -not $NewSecretId) {
    throw "-DockerHost needs -NewSecretId: an existing secret_id cannot be read back from Vault."
}

$engineName = "docker"
$policyName = "docker"
$roleName = "docker01"
$tokenTtlSeconds = 300
$tokenMaxTtlSeconds = 600
$policyText = @"
path "$engineName/data/*" {
  capabilities = ["read"]
}
"@

$plainToken = [System.Net.NetworkCredential]::new("", $VaultToken).Password
$requestHeaders = @{ "X-Vault-Token" = $plainToken }

function Invoke-VaultRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet("Get", "Post", "Put")][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body = $null
    )
    $arguments = @{ Uri = "$VaultAddr/v1/$Path"; Method = $Method; Headers = $requestHeaders }
    if ($null -ne $Body) {
        $arguments.Body = $Body | ConvertTo-Json -Depth 5
        $arguments.ContentType = "application/json"
    }
    Invoke-RestMethod @arguments
}

# Vault answers 404 for a path that does not exist yet, which is a state here and no error
function Get-VaultData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $data = $null
    try {
        $data = (Invoke-VaultRequest -Method Get -Path $Path).data
    } catch {
        $response = $_.Exception.PSObject.Properties["Response"]
        if ($null -eq $response -or $null -eq $response.Value -or [int]$response.Value.StatusCode -ne 404) {
            throw
        }
    }
    $data
}

function Get-ResourceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Resource,
        [Parameter(Mandatory)][ValidateSet("Created", "Updated", "Unchanged")][string]$State
    )
    [pscustomobject]@{ Resource = $Resource; State = $State }
}

function Set-ApproleAuthMethod {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $state = "Unchanged"
    $authMounts = Invoke-VaultRequest -Method Get -Path "sys/auth"
    if ($authMounts.PSObject.Properties.Name -notcontains "approle/") {
        $state = "Created"
        if ($PSCmdlet.ShouldProcess("auth/approle", "Enable the approle auth method")) {
            Invoke-VaultRequest -Method Post -Path "sys/auth/approle" -Body @{ type = "approle" } | Out-Null
        }
    }
    Get-ResourceState -Resource "auth method approle/" -State $state
}

function Set-KvEngine {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $state = "Unchanged"
    $mounts = Invoke-VaultRequest -Method Get -Path "sys/mounts"
    $mountNames = @($mounts.PSObject.Properties.Name)
    if ($mounts.PSObject.Properties.Name -contains "data") {
        $mountNames += @($mounts.data.PSObject.Properties.Name)
    }
    if ($mountNames -notcontains "$engineName/") {
        $state = "Created"
        if ($PSCmdlet.ShouldProcess("$engineName/", "Mount a KV v2 engine")) {
            Invoke-VaultRequest -Method Post -Path "sys/mounts/$engineName" -Body @{ type = "kv-v2" } | Out-Null
        }
    }
    Get-ResourceState -Resource "KV v2 engine $engineName/" -State $state
}

function Set-ReadOnlyPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $existing = Get-VaultData -Path "sys/policies/acl/$policyName"
    $state = "Unchanged"
    if ($null -eq $existing) {
        $state = "Created"
    } elseif ($existing.policy.Trim() -ne $policyText.Trim()) {
        $state = "Updated"
    }
    if ($state -ne "Unchanged" -and $PSCmdlet.ShouldProcess($policyName, "Write the policy")) {
        Invoke-VaultRequest -Method Put -Path "sys/policies/acl/$policyName" -Body @{ policy = $policyText } | Out-Null
    }
    Get-ResourceState -Resource "policy $policyName" -State $state
}

# Vault returns a single host without its prefix in token_bound_cidrs (100.64.0.10) and with it in
# secret_id_bound_cidrs (100.64.0.10/32), so the lists are compared without /32 and /128
function ConvertTo-CidrKey {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Cidr = @())
    (@($Cidr | ForEach-Object { $_ -replace '/(32|128)$', '' } | Sort-Object) -join ",")
}

# Both CIDR fields are always sent: Vault keeps a value that is left out on an update, an empty list removes
# the binding. A secret_id keeps the binding it was created with, so after a change create a new one.
function Set-DockerAppRole {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $existing = Get-VaultData -Path "auth/approle/role/$roleName"
    $wantedCidrs = ConvertTo-CidrKey -Cidr $AllowedCidr
    $state = "Unchanged"
    if ($null -eq $existing) {
        $state = "Created"
    } elseif ((@($existing.token_policies) -join ",") -ne $policyName `
            -or $existing.token_ttl -ne $tokenTtlSeconds `
            -or $existing.token_max_ttl -ne $tokenMaxTtlSeconds `
            -or $existing.secret_id_ttl -ne 0 `
            -or (ConvertTo-CidrKey -Cidr @($existing.token_bound_cidrs)) -ne $wantedCidrs `
            -or (ConvertTo-CidrKey -Cidr @($existing.secret_id_bound_cidrs)) -ne $wantedCidrs) {
        $state = "Updated"
    }
    if ($state -ne "Unchanged" -and $PSCmdlet.ShouldProcess($roleName, "Write the AppRole")) {
        $role = @{
            token_policies        = @($policyName)
            token_ttl             = $tokenTtlSeconds
            token_max_ttl         = $tokenMaxTtlSeconds
            secret_id_ttl         = 0
            token_bound_cidrs     = @($AllowedCidr)
            secret_id_bound_cidrs = @($AllowedCidr)
        }
        Invoke-VaultRequest -Method Post -Path "auth/approle/role/$roleName" -Body $role | Out-Null
    }
    if ($AllowedCidr.Count -eq 0) {
        Write-Warning "No -AllowedCidr: the secret_id works from every address that reaches Vault."
    }
    Get-ResourceState -Resource "AppRole $roleName" -State $state
}

# Writes a credential file on the Docker host over SSH. The content goes through stdin of ssh, so it is
# neither an argument (process list) nor output. The file is written next to its target and moved over it.
function Install-HostCredential {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Content
    )
    $target = "/etc/gitops/$FileName"
    if ($PSCmdlet.ShouldProcess("${SshUser}@${DockerHost}:$target", "Write the file (mode 600)")) {
        $remoteCommand = "umask 077 && install -d -m 700 /etc/gitops && cat > $target.new && mv -f $target.new $target"
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "ssh"
        $startInfo.Arguments = (($SshArgument + @("$SshUser@$DockerHost", $remoteCommand)) | ForEach-Object { "`"$_`"" }) -join " "
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "ssh to ${SshUser}@${DockerHost} failed (exit code $($process.ExitCode)) while writing ${target}: $errorText"
        }
    }
    Get-ResourceState -Resource "file ${DockerHost}:$target" -State "Updated"
}

# Creates a secret_id and destroys the older ones. With -DockerHost the files are written to the host first,
# so a failed SSH login leaves the old secret_id valid. Without it the secret_id is shown once.
function New-DockerSecretId {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess($roleName, "Create a new secret_id and destroy the older ones")) {
        $created = (Invoke-VaultRequest -Method Post -Path "auth/approle/role/$roleName/secret-id" -Body @{ }).data
        $roleId = (Invoke-VaultRequest -Method Get -Path "auth/approle/role/$roleName/role-id").data.role_id
        if ($DockerHost) {
            Install-HostCredential -FileName "role_id" -Content $roleId
            Install-HostCredential -FileName "secret_id" -Content $created.secret_id
        }
        $accessors = (Invoke-VaultRequest -Method Get -Path "auth/approle/role/$roleName/secret-id?list=true").data.keys
        foreach ($accessor in $accessors | Where-Object { $_ -ne $created.secret_id_accessor }) {
            Invoke-VaultRequest -Method Post -Path "auth/approle/role/$roleName/secret-id-accessor/destroy" `
                -Body @{ secret_id_accessor = $accessor } | Out-Null
        }
        if (-not $DockerHost) {
            Write-Host "role_id   : $roleId" -ForegroundColor Yellow
            Write-Host "secret_id : $($created.secret_id)" -ForegroundColor Yellow
            Write-Host "Shown once and not saved. On the Docker host as root:"
            Write-Host "  install -d -m 700 /etc/gitops"
            Write-Host "  (umask 077; cat > /etc/gitops/secret_id)   # paste the secret_id, then Ctrl-D"
            Write-Host "  (umask 077; cat > /etc/gitops/role_id)     # paste the role_id, then Ctrl-D"
        }
    }
}

Set-ApproleAuthMethod
Set-KvEngine
Set-ReadOnlyPolicy
Set-DockerAppRole
if ($NewSecretId) {
    New-DockerSecretId
}
