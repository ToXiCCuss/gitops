<#
.SYNOPSIS
Creates the random secrets of all apps in Vault (KV engines argocd, docker, dev and prod) that do not exist yet.

.DESCRIPTION
Reads scripts\vault\generated-secrets.txt (<mount> <secret> <key> <length or =<mount>/<secret>#<key>>, one key per line) and creates
every key that is missing in <mount>/<secret>, for example argocd/jenkins or prod/er-launcher-service. A key that exists is never
changed. A random value has the given length and consists of A-Z, a-z and 0-9 (each kind at least once), like
openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | head -c 64. A line with =<mount>/<secret>#<key> takes the value of that other key when
its own key is missing (the OIDC client secrets that Keycloak and the app have to share).

Log in first with your own Keycloak login, then run the script. The root token is refused. The login needs create, read and update
in every mount that is processed: the role admin (keycloak_admin) for argocd and docker, the role developer (keycloak_developer)
is enough for dev and prod only (-Mount dev, -Mount prod).

    $env:VAULT_ADDR = 'https://vault.k8sdev.rjst.de'
    vault login -method=oidc role=default
    .\scripts\vault\Generate-Secrets.ps1 -DryRun
    .\scripts\vault\Generate-Secrets.ps1

Idempotent: a second run reports "unchanged". Values come from the random number generator of the system, go to Vault through the
standard input of the vault process (not through its command line) and are never printed. Values that are set from outside (Hetzner
and NetBird token, Discord secret, webhooks) or by other scripts (database logins: db_create.sh, S3 keys: setup-rustfs.sh, NetBird
installer values) are not in the list.
Windows PowerShell 5.1 or PowerShell 7 and the Vault CLI (vault) are needed.
#>
[CmdletBinding()]
param(
    [ValidateSet('argocd', 'docker', 'dev', 'prod', 'all')][string]$Mount = 'all',
    [switch]$DryRun,
    [string]$ListFile
)

$ErrorActionPreference = 'Stop'
# The default is set here and not in the parameter block: $PSScriptRoot is empty there in Windows PowerShell 5.1 when started with -File.
if (-not $ListFile) { $ListFile = Join-Path $PSScriptRoot 'generated-secrets.txt' }

$MinimumLength = 16
$MaximumLength = 128
$Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
$MountPattern = '^[a-z][a-z0-9-]*$'
$SecretPattern = '^[a-z][a-z0-9-]*$'
$KeyPattern = '^[A-Za-z][A-Za-z0-9._-]*$'
$CopyPattern = '^=([a-z][a-z0-9-]*)/([a-z][a-z0-9-]*)#([A-Za-z][A-Za-z0-9._-]*)$'
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

# Reads one key of a secret. The value stays in memory (it is written to Vault again, never shown); $null when it does not exist.
function Read-VaultKey {
    param([string]$MountName, [string]$Secret, [string]$Key)

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $script:VaultPath
    $start.Arguments = "kv get -mount=$MountName -field=$Key $Secret"
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($start)
    $value = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -eq 0) { return $value.TrimEnd("`r", "`n") }
    return $null
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

# True when the text has a lower case letter, an upper case letter and a digit.
function Test-HasAllKinds {
    param([string]$Text)

    return ($Text -cmatch '[a-z]') -and ($Text -cmatch '[A-Z]') -and ($Text -match '[0-9]')
}

# Random alphanumeric text from the cryptographic generator of the system (no modulo bias) with letters and digits in it.
function New-RandomText {
    param([Parameter(Mandatory)][int]$Length)

    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buffer = New-Object byte[] 256
    try {
        do {
            $text = New-Object System.Text.StringBuilder
            while ($text.Length -lt $Length) {
                $generator.GetBytes($buffer)
                foreach ($byte in $buffer) {
                    if ($byte -lt $UnbiasedLimit -and $text.Length -lt $Length) { [void]$text.Append($Alphabet[$byte % $Alphabet.Length]) }
                }
            }
        } until (Test-HasAllKinds -Text $text.ToString())
    }
    finally { $generator.Dispose() }
    return $text.ToString()
}

# The list is read by a script that writes to Vault, so every line is checked before anything is written.
function ConvertTo-Entry {
    param([string]$Line)

    $fields = $Line.Trim() -split '\s+'
    if ($fields.Count -ne 4) { throw "Invalid line in the list: $Line" }
    $mountName, $secret, $key, $source = $fields
    if ($mountName -cnotmatch $MountPattern) { throw "Invalid mount in the list: $mountName" }
    if ($secret -cnotmatch $SecretPattern) { throw "Invalid secret name in the list: $secret" }
    if ($key -cnotmatch $KeyPattern) { throw "Invalid key in the list: $mountName/$secret $key" }
    $entry = [pscustomobject]@{ Mount = $mountName; Secret = $secret; Key = $key; Length = 0; SourceMount = $null; SourceSecret = $null; SourceKey = $null }
    if ($source -cmatch $CopyPattern) {
        $entry.SourceMount = $Matches[1]; $entry.SourceSecret = $Matches[2]; $entry.SourceKey = $Matches[3]
    }
    elseif ($source -match '^[0-9]+$' -and [int]$source -ge $MinimumLength -and [int]$source -le $MaximumLength) {
        $entry.Length = [int]$source
    }
    else { throw "Invalid length or source for $mountName/$secret ${key}: $source (from $MinimumLength to $MaximumLength, or =<mount>/<secret>#<key>)" }
    return $entry
}

# patch keeps the other keys of the secret; put with -cas=0 creates a secret that does not exist yet and never overwrites one.
function Save-Key {
    param([string]$MountName, [string]$Secret, [string]$Key, [string]$Value)

    $patch = Invoke-Vault -Arguments @('kv', 'patch', '-method=rw', "-mount=$MountName", $Secret, "$Key=-") -StandardInput $Value
    if ($patch.ExitCode -eq 0) { return $true }
    $put = Invoke-Vault -Arguments @('kv', 'put', '-cas=0', "-mount=$MountName", $Secret, "$Key=-") -StandardInput $Value
    return ($put.ExitCode -eq 0)
}

# The value of a new key: random, or taken over from the other key of a copy line ($null when that key does not exist).
function Get-NewValue {
    param([pscustomobject]$Entry)

    if ($Entry.SourceMount) { return Read-VaultKey -MountName $Entry.SourceMount -Secret $Entry.SourceSecret -Key $Entry.SourceKey }
    return New-RandomText -Length $Entry.Length
}

function Get-NewKeyDescription {
    param([pscustomobject]$Entry)

    if ($Entry.SourceMount) { return "copy of $($Entry.SourceMount)/$($Entry.SourceSecret) $($Entry.SourceKey)" }
    return "$($Entry.Length) characters"
}

$script:VaultPath = (Get-Command vault -ErrorAction SilentlyContinue).Source
if (-not $script:VaultPath) { throw 'The Vault CLI (vault) is required. winget install HashiCorp.Vault' }
if (-not (Test-Path -LiteralPath $ListFile -PathType Leaf)) { throw "List not found: $ListFile" }

$lines = @(Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() -ne '' -and -not $_.TrimStart().StartsWith('#') })
$entries = @($lines | ForEach-Object { ConvertTo-Entry -Line $_ } | Where-Object { $Mount -eq 'all' -or $_.Mount -eq $Mount })
$created = 0; $unchanged = 0; $failed = 0

Write-Host "`n== Login at $env:VAULT_ADDR" -ForegroundColor Cyan
Assert-OwnLogin
Write-Success 'Logged in with your own token'

$currentMount = $null
foreach ($entry in $entries) {
    if ($entry.Mount -ne $currentMount) {
        $currentMount = $entry.Mount
        Write-Host "`n== Mount $currentMount" -ForegroundColor Cyan
    }
    $name = "$($entry.Mount)/$($entry.Secret) $($entry.Key)"
    $exists = (Invoke-Vault -Arguments @('kv', 'get', "-mount=$($entry.Mount)", "-field=$($entry.Key)", $entry.Secret)).ExitCode -eq 0
    if ($exists) {
        $unchanged++
        Write-Info "${name}: unchanged"
    }
    elseif ($DryRun) {
        $created++
        Write-Notice "${name}: would be created ($(Get-NewKeyDescription -Entry $entry))"
    }
    else {
        $value = Get-NewValue -Entry $entry
        if ($null -eq $value -or $value -eq '') {
            $failed++
            Write-Failure "${name}: the source $($entry.SourceMount)/$($entry.SourceSecret) $($entry.SourceKey) does not exist or cannot be read"
        }
        elseif (Save-Key -MountName $entry.Mount -Secret $entry.Secret -Key $entry.Key -Value $value) {
            $created++
            Write-Success "${name}: created ($(Get-NewKeyDescription -Entry $entry))"
        }
        else {
            $failed++
            Write-Failure "${name}: could not be written (does your login have create and update in $($entry.Mount)/?)"
        }
    }
}

Write-Host ''
if ($DryRun) { Write-Info "Dry run: $created key(s) would be created, $unchanged unchanged. Nothing was written." }
else { Write-Info "$created key(s) created, $unchanged unchanged, $failed failed." }
if ($failed -gt 0) { exit 1 }
