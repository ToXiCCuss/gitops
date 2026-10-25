---
paths:
  - "**/*.ps1"
  - "**/*.psm1"
  - "**/*.psd1"
---

# PowerShell scripts

## Idempotency (mandatory)
- Every script is idempotent: a second run with the same parameters changes nothing, reports that nothing changed and does not fail. A run that was aborted can simply be started again.
- Check the actual state before every change and act only on a difference: `Test-Path` before `New-Item`, compare content before writing, read a setting before setting it. Creating a resource that already exists is not an error, it is `unchanged`.
- Never `New-Item -Force` on an existing file (it truncates it) and no `Add-Content` without checking that the line is missing. Write files atomically: write to a temp file in the same folder, then `Move-Item -Force` over the target.
- Name functions by the desired state where possible (`Set-*`, `Install-*` that only acts on a difference) and output per resource whether it was `Created`, `Updated` or `Unchanged`.
- Every state-changing script or function declares `[CmdletBinding(SupportsShouldProcess)]` and wraps each change in `if ($PSCmdlet.ShouldProcess(...))`, so `-WhatIf` shows the plan without changing anything.

## Structure
- Compatible with Windows PowerShell 5.1 and PowerShell 7: no `&&`/`||`, no `?:`, `??` or `?.`.
- Start with `[CmdletBinding()]` and a typed `param()` block with validation (`[Parameter(Mandatory)]`, `[ValidateSet()]`, `[ValidateNotNullOrEmpty()]`), then `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Functions `Verb-Noun` with approved verbs (`Get-Verb`), `PascalCase` for functions and parameters, `camelCase` for local variables. No aliases in scripts (`%`, `?`, `gci`, `ls`, `cat`), full cmdlet and parameter names.
- Comment-based help (`.SYNOPSIS`, `.PARAMETER`, `.EXAMPLE`) for every script and exported function.

## Rules
- Return objects, not formatted strings. `Write-Host` only for status messages to the user; diagnostics via `Write-Verbose`, errors via `throw` or `Write-Error`.
- No empty `catch`; catch specific exceptions only where they are handled.
- Paths with `Join-Path`, `$PSScriptRoot` and `-LiteralPath`, never assembled by string concatenation or relative to the current folder.
- Encoding always explicit: write with `[System.IO.File]::WriteAllText(..., (New-Object System.Text.UTF8Encoding($false)))` or `-Encoding utf8`. Script files contain only ASCII characters; otherwise UTF-8 with BOM, because Windows PowerShell 5.1 reads files without BOM as ANSI.
- No secrets in parameters, files or output; use `SecureString`/`PSCredential` or environment variables.
- Native executables: check `$LASTEXITCODE` after each call and throw on a non-zero value.

## Check before "done"
- `Invoke-ScriptAnalyzer -Path <script> -Settings PSGallery` without findings.
- Run the script twice where it is safe locally (temp folder, `-WhatIf`): the second run must report only `Unchanged`. If there is a Pester 5 suite, it contains this double-run test.
