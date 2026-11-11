<#
.SYNOPSIS
Creates the random secrets of the Spring apps in Vault (KV engines dev and prod) that do not exist yet.

.DESCRIPTION
Reads scripts\vault\generated-app-secrets.txt (<app> <key> <length>, one key per line) and creates every key that is missing in
<environment>/<app>, for example prod/er-launcher-service. A key that exists is never changed.

Log in first with your own Keycloak login, then run the script. The root token is refused. The login needs the policy
keycloak_developer (create, read, update in dev/ and prod/); the AppRole of docker01 cannot write there on purpose.

    $env:VAULT_ADDR = 'https://vault.k8sdev.rjst.de'
    vault login -method=oidc role=default
    .\scripts\vault\Generate-AppSecrets.ps1 -Environment all -DryRun
    .\scripts\vault\Generate-AppSecrets.ps1 -Environment all

Idempotent: a second run reports "unchanged". Values come from the random number generator of the system, go to Vault through
the standard input of the vault process (not through its command line) and are never printed. Values that are set from outside
(Discord secret, webhooks) or by other scripts (database logins: db_create.sh, S3 keys: setup-rustfs.sh) are not in the list.
Windows PowerShell 5.1 or PowerShell 7 and the Vault CLI (vault) are needed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'prod', 'all')][string]$Environment,
    [switch]$DryRun,
    [string]$ListFile
)

$ErrorActionPreference = 'Stop'
# The default is set here and not in the parameter block: $PSScriptRoot is empty there in Windows PowerShell 5.1 when started with -File.
if (-not $ListFile) { $ListFile = Join-Path $PSScriptRoot 'generated-app-secrets.txt' }

$MinimumLength = 32
$MaximumLength = 128
$Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$AppPattern = '^[a-z][a-z0-9-]*$'
$KeyPattern = '^[A-Za-z][A-Za-z0-9._-]*$'
# 62 characters: a byte below 248 (4 x 62) maps without bias, a larger one is thrown away
$UnbiasedLimit = 248

if (-not $env:VAULT_ADDR) { $env:VAULT_ADDR = 'https://vault.k8sdev.rjst.de' }

function Write-Info($Text) { Write-Host "[INFO]  $Text" -ForegroundColor Cyan }
function Write-Success($Text) { Write-Host "[OK]    $Text" -ForegroundColor Green }
function Write-Notice($Text) { Write-Host "[WARN]  $Text" -ForegroundColor Yellow }
function Write-Failure($Text) { Write-Host "[ERROR] $Text" -ForegroundColor Red }

# The standard input of a started process is written with the encoding of the console. With a UTF-8 console that includes a byte order
# mark in front of the value, which would end up in the secret (Windows PowerShell 5.1 cannot choose the encoding per process).
# So the console encoding is switched to UTF-8 without BOM while the process starts; if that is not possible, nothing is written.
function Start-ProcessWithoutBom {
    param([Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo)

    $previous = [Console]::InputEncoding
    $switched = $false
    if ($StartInfo.RedirectStandardInput -and $previous.GetPreamble().Length -gt 0) {
        try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false); $switched = $true }
        catch { throw 'This console writes a byte order mark to the standard input of vault and the encoding cannot be changed. Use a normal PowerShell console (not a hosted one).' }
    }
    try { return [System.Diagnostics.Process]::Start($StartInfo) }
    finally { if ($switched) { [Console]::InputEncoding = $previous } }
}

# Runs vault with the given arguments. The optional value goes to its standard input without a line break, so neither the
# process list nor the history shows it. Returns the exit code and the text of stderr; stdout is discarded on purpose.
function Invoke-Vault {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$StandardInput
    )

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:VaultPath
    $start.Arguments = $Arguments -join ' '
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.RedirectStandardInput = $PSBoundParameters.ContainsKey('StandardInput')
    $start.CreateNoWindow = $true
    $process = Start-ProcessWithoutBom -StartInfo $start
    if ($start.RedirectStandardInput) {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($StandardInput)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
    }
    $errorText = $process.StandardError.ReadToEnd()
    $null = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Error = $errorText.Trim() }
}

# vault token lookup prints the token and its policies; the policies line is the only thing that is looked at, nothing is shown.
function Assert-OwnLogin {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:VaultPath
    $start.Arguments = 'token lookup'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($start)
    $lookup = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Not logged in to $env:VAULT_ADDR. Log in first: vault login -method=oidc role=default" }
    $policies = ($lookup -split "`r?`n" | Where-Object { $_ -match '^policies\s' }) -join ' '
    # The root token needs no policy to write anything: a script that runs with it could change every secret.
    if ($policies -match '\broot\b') { throw 'Logged in with the root token. Use your own login: vault login -method=oidc role=default' }
}

# Random alphanumeric text from the cryptographic generator of the system (no modulo bias).
function New-RandomText {
    param([Parameter(Mandatory)][int]$Length)

    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 256
    $text = New-Object System.Text.StringBuilder
    try {
        while ($text.Length -lt $Length) {
            $generator.GetBytes($buffer)
            foreach ($byte in $buffer) {
                if ($byte -lt $UnbiasedLimit -and $text.Length -lt $Length) { [void]$text.Append($Alphabet[$byte % $Alphabet.Length]) }
            }
        }
    }
    finally { $generator.Dispose() }
    return $text.ToString()
}

# The list is read by a script that writes to Vault, so every field is checked.
function Assert-ValidLine {
    param([string]$App, [string]$Key, [string]$Length)

    if ($App -cnotmatch $AppPattern) { throw "Invalid app name in the list: $App" }
    if ($Key -cnotmatch $KeyPattern) { throw "Invalid key in the list: $Key" }
    if ($Length -notmatch '^[0-9]+$' -or [int]$Length -lt $MinimumLength -or [int]$Length -gt $MaximumLength) {
        throw "Invalid length for $App ${Key}: $Length (from $MinimumLength to $MaximumLength)"
    }
}

# patch keeps the other keys of the secret; put with -cas=0 creates a secret that does not exist yet and never overwrites one.
function Save-Key {
    param([string]$EnvironmentName, [string]$App, [string]$Key, [string]$Value)

    $patch = Invoke-Vault -Arguments @('kv', 'patch', '-method=rw', "-mount=$EnvironmentName", $App, "$Key=-") -StandardInput $Value
    if ($patch.ExitCode -eq 0) { return $true }
    $put = Invoke-Vault -Arguments @('kv', 'put', '-cas=0', "-mount=$EnvironmentName", $App, "$Key=-") -StandardInput $Value
    return ($put.ExitCode -eq 0)
}

$script:VaultPath = (Get-Command vault -ErrorAction SilentlyContinue).Source
if (-not $script:VaultPath) { throw 'The Vault CLI (vault) is required. winget install HashiCorp.Vault' }
if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) { throw "List not found: $ListFile" }

$environments = if ($Environment -eq 'all') { @('dev', 'prod') } else { @($Environment) }
$entries = @(Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') })
$created = 0; $unchanged = 0; $failed = 0

Write-Host "`n== Login at $env:VAULT_ADDR" -ForegroundColor Cyan
Assert-OwnLogin
Write-Success 'Logged in with your own token'

foreach ($environmentName in $environments) {
    Write-Host "`n== Environment $environmentName" -ForegroundColor Cyan
    foreach ($entry in $entries) {
        $fields = $entry.Trim() -split '\s+'
        if ($fields.Count -ne 3) { throw "Invalid line in the list: $entry" }
        $app, $key, $length = $fields
        Assert-ValidLine -App $app -Key $key -Length $length

        $exists = (Invoke-Vault -Arguments @('kv', 'get', "-mount=$environmentName", "-field=$key", $app)).ExitCode -eq 0
        if ($exists) {
            $unchanged++
            Write-Info "$environmentName/$app ${key}: unchanged"
        }
        elseif ($DryRun) {
            $created++
            Write-Notice "$environmentName/$app ${key}: would be created ($length characters)"
        }
        elseif (Save-Key -EnvironmentName $environmentName -App $app -Key $key -Value (New-RandomText -Length ([int]$length))) {
            $created++
            Write-Success "$environmentName/$app ${key}: created ($length characters)"
        }
        else {
            $failed++
            Write-Failure "$environmentName/$app ${key}: could not be written (does your login have create and update in ${environmentName}/?)"
        }
    }
}

Write-Host ''
if ($DryRun) { Write-Info "Dry run: $created key(s) would be created, $unchanged unchanged. Nothing was written." }
else { Write-Info "$created key(s) created, $unchanged unchanged, $failed failed." }
if ($failed -gt 0) { exit 1 }
