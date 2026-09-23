<#
.SYNOPSIS
  Install the Claude Code auto-continue Stop hook.

.DESCRIPTION
  Copies claude\auto_continue.py into a hooks folder and registers it as a Stop hook,
  so Claude carries on with routine next steps instead of ending its turn. The hook
  still lets Claude stop when its last message mentions a human gate (approval,
  spending, credentials, deletes, pushes, ledger writes), says it is waiting on a
  background task, or after 8 automatic continues in a row.

  -Scope User     ~\.claude\hooks\ and ~\.claude\settings.json (every project)
  -Scope Project  <ProjectDir>\.claude\hooks\ and <ProjectDir>\.claude\settings.local.json

  Settings are merged, never replaced, and written as UTF-8 without a BOM. The existing
  settings file is backed up with a .bak-auto-continue-<timestamp> suffix first.
  Start a new Claude Code session afterwards; hooks load at session start.

.EXAMPLE
  .\install_claude_auto_continue.ps1 -Scope User
  .\install_claude_auto_continue.ps1 -Scope Project -ProjectDir C:\src\myrepo
  .\install_claude_auto_continue.ps1 -Scope User -VerifyOnly
  .\install_claude_auto_continue.ps1 -Scope User -Uninstall
#>
param(
    [Parameter(Mandatory)][ValidateSet('User','Project')][string]$Scope,
    [string]$ProjectDir = (Get-Location).Path,
    [string]$UserHome = $HOME,
    [switch]$VerifyOnly,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'claude\auto_continue.py'
if (-not (Test-Path $source)) { throw "missing $source" }

if ($Scope -eq 'User') {
    $claudeDir = Join-Path $UserHome '.claude'
    $settings  = Join-Path $claudeDir 'settings.json'
    $hookPath  = Join-Path $claudeDir 'hooks\auto_continue.py'
    $command   = 'python "' + ($hookPath -replace '\\','/') + '"'
} else {
    $claudeDir = Join-Path $ProjectDir '.claude'
    $settings  = Join-Path $claudeDir 'settings.local.json'
    $hookPath  = Join-Path $claudeDir 'hooks\auto_continue.py'
    $command   = 'python .claude/hooks/auto_continue.py'
}

function Read-Settings([string]$Path) {
    if (-not (Test-Path $Path)) { return [pscustomobject]@{} }
    $raw = [IO.File]::ReadAllText($Path).TrimStart([char]0xFEFF)
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    return $raw | ConvertFrom-Json
}

function Get-StopEntries($json) {
    if (-not $json.PSObject.Properties['hooks']) { return @() }
    if (-not $json.hooks.PSObject.Properties['Stop']) { return @() }
    return @($json.hooks.Stop)
}

function Test-Installed($json) {
    foreach ($e in (Get-StopEntries $json)) {
        foreach ($h in @($e.hooks)) { if ($h.command -like '*auto_continue.py*') { return $true } }
    }
    return $false
}

$json = Read-Settings $settings
$installed = Test-Installed $json

if ($VerifyOnly) {
    Write-Host "settings : $settings"
    Write-Host "hook file: $hookPath  exists=$(Test-Path $hookPath)"
    Write-Host "registered as Stop hook: $installed"
    $bom = (Test-Path $settings) -and ([IO.File]::ReadAllBytes($settings)[0] -eq 0xEF)
    Write-Host "settings has BOM: $bom"
    return
}

if (Test-Path $settings) {
    Copy-Item $settings "$settings.bak-auto-continue-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
}

if ($Uninstall) {
    if ($installed) {
        $kept = @(Get-StopEntries $json | Where-Object {
            -not (@($_.hooks) | Where-Object { $_.command -like '*auto_continue.py*' }) })
        if ($kept.Count) { $json.hooks.Stop = $kept } else { $json.hooks.PSObject.Properties.Remove('Stop') }
        if (-not @($json.hooks.PSObject.Properties).Count) { $json.PSObject.Properties.Remove('hooks') }
    }
    if (Test-Path $hookPath) { Remove-Item $hookPath -Force }
    Write-Host "auto-continue hook removed from $settings"
} else {
    New-Item -ItemType Directory -Force (Split-Path $hookPath -Parent) | Out-Null
    Copy-Item $source $hookPath -Force
    if (-not $installed) {
        $entry = [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $command }) }
        if (-not $json.PSObject.Properties['hooks']) {
            $json | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
        }
        $stop = @(Get-StopEntries $json) + $entry
        $json.hooks | Add-Member -Force -NotePropertyName Stop -NotePropertyValue $stop
    }
    Write-Host "hook file : $hookPath"
    Write-Host "registered: $command"
}

New-Item -ItemType Directory -Force $claudeDir | Out-Null
$text = $json | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($settings, $text, (New-Object Text.UTF8Encoding $false))
Write-Host "wrote $settings (UTF-8, no BOM). Start a new Claude Code session to load it."
