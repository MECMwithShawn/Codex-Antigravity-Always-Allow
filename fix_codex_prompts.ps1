<#
.SYNOPSIS
Disable repeated Codex command approval prompts for this Windows user.

.DESCRIPTION
Updates:

- C:\Users\<user>\.codex\config.toml
  - approval_policy = "never"
  - sandbox_mode = "danger-full-access"

The script is idempotent and creates timestamped .bak files before editing.
Restart Codex/Antigravity after running so the active session reloads the settings.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$UserHome = $env:USERPROFILE,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[codex-no-prompts] $Message"
}

function Backup-File {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$Path.bak-no-prompts-$stamp"
    if (-not $VerifyOnly) {
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    return $backup
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($VerifyOnly) {
            Write-Step "missing directory: $Path"
            return
        }
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-CodexConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    $exists = Test-Path -LiteralPath $Path
    if ($VerifyOnly) {
        if (-not $exists) {
            Write-Step "Codex config missing: $Path"
            return
        }
        $text = Get-Content -Raw -LiteralPath $Path
        Write-Step "Codex approval_policy present: $($text -match '(?m)^approval_policy\s*=\s*""never""')"
        Write-Step "Codex sandbox_mode present: $($text -match '(?m)^sandbox_mode\s*=\s*""danger-full-access""')"
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $backup = Backup-File -Path $Path
    if ($backup) {
        Write-Step "backed up Codex config to $backup"
    }

    $text = ""
    if ($exists) {
        $text = Get-Content -Raw -LiteralPath $Path
    }

    if ($text -notmatch '(?m)^approval_policy\s*=') {
        $text = "approval_policy = ""never""`r`n" + $text
    } else {
        $text = $text -replace '(?m)^approval_policy\s*=.*$', 'approval_policy = "never"'
    }

    if ($text -notmatch '(?m)^sandbox_mode\s*=') {
        $text = $text -replace '(?m)^(approval_policy\s*=.*)$', "`$1`r`nsandbox_mode = ""danger-full-access"""
    } else {
        $text = $text -replace '(?m)^sandbox_mode\s*=.*$', 'sandbox_mode = "danger-full-access"'
    }

    Set-Content -LiteralPath $Path -Value $text -NoNewline
    Write-Step "updated Codex config: $Path"
}

$codexConfig = Join-Path $UserHome ".codex\config.toml"

Write-Step "user home: $UserHome"
Ensure-CodexConfig -Path $codexConfig

if (-not $VerifyOnly) {
    Write-Step "done. Fully restart Codex/Antigravity so the active session reloads these settings."
}
