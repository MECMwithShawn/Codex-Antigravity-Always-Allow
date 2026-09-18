<#
.SYNOPSIS
  Export / import OpenAI Codex + Antigravity permission & settings files
  (~\.codex and ~\.gemini).

.DESCRIPTION
  Export mode: snapshots permission-relevant config into .\settings\ next to
  this script (settings\codex\... and settings\gemini\...), plus manifest.json.

  Captured from ~\.codex:
    - config.toml        (approval_policy, sandbox_mode, per-project trust
                          levels, MCP servers, plugins, features)
    - AGENTS.md          (global agent instructions)
    - rules\             (command approval rules)
    - automations\       (scheduled automations)
    - skills\<user>      (user-created skills; bundled .system skills excluded)

  Captured from ~\.gemini (Antigravity):
    - settings.json, GEMINI.md
    - config\config.json, config\GEMINI.md, config\mcp_config.json
    - config\projects\*.json  (permission policies incl. outside-of-project;
                               *.bak-* backups excluded)

  Import mode: restores everything back to ~\.codex / ~\.gemini, backing up
  any existing file as *.pre-restore-<timestamp> first.

  NEVER exports ~\.codex\auth.json (login tokens do not belong in OneDrive;
  sign in again after the OS reload). Session databases, caches, and history
  are also excluded - state, not settings.

  NOTE: Antigravity project files under config\projects\ are keyed by
  workspace GUIDs that a fresh install regenerates. After restoring, run the
  bundled fix_antigravity_no_prompts.ps1 once per new workspace so new GUID
  configs get the always-allow policies too.

.EXAMPLE
  .\CodexSettings-Backup.ps1 -Mode Export
  .\CodexSettings-Backup.ps1 -Mode Import
  .\CodexSettings-Backup.ps1 -Mode Import -WhatIfOnly   # dry run
#>
param(
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Mode,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$BackupRoot   = Join-Path $PSScriptRoot 'settings'
$ManifestPath = Join-Path $PSScriptRoot 'manifest.json'

# Roots: key used in manifest / backup subfolder -> actual location.
$Roots = @{
    codex  = Join-Path $HOME '.codex'
    gemini = Join-Path $HOME '.gemini'
}

function Copy-Entry {
    param([string]$RootKey, [string]$AbsPath)
    $rel  = $AbsPath.Substring($Roots[$RootKey].Length).TrimStart('\')
    $dest = Join-Path (Join-Path $BackupRoot $RootKey) $rel
    $dd   = Split-Path $dest -Parent
    if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Path $dd -Force | Out-Null }
    Copy-Item $AbsPath $dest -Force
    Write-Host "exported  [$RootKey] $rel"
    [pscustomobject]@{ root = $RootKey; rel = $rel }
}

if ($Mode -eq 'Export') {
    if (-not (Test-Path $Roots.codex)) { throw "$($Roots.codex) not found - is Codex installed for this user?" }
    if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    $entries = @()

    # --- Codex (~\.codex) ---
    foreach ($f in @('config.toml','AGENTS.md')) {
        $p = Join-Path $Roots.codex $f
        if (Test-Path $p) { $entries += Copy-Entry codex $p }
    }
    foreach ($d in @('rules','automations')) {
        $p = Join-Path $Roots.codex $d
        if (-not (Test-Path $p)) { continue }
        Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $entries += Copy-Entry codex $_.FullName }
    }
    $skillsDir = Join-Path $Roots.codex 'skills'
    if (Test-Path $skillsDir) {
        Get-ChildItem $skillsDir -Directory | Where-Object { $_.Name -ne '.system' } |
            ForEach-Object {
                Get-ChildItem $_.FullName -Recurse -File -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $entries += Copy-Entry codex $_.FullName }
            }
    }

    # --- Antigravity (~\.gemini) ---
    if (Test-Path $Roots.gemini) {
        foreach ($f in @('settings.json','GEMINI.md',
                         'config\config.json','config\GEMINI.md','config\mcp_config.json')) {
            $p = Join-Path $Roots.gemini $f
            if (Test-Path $p) { $entries += Copy-Entry gemini $p }
        }
        $projDir = Join-Path $Roots.gemini 'config\projects'
        if (Test-Path $projDir) {
            Get-ChildItem $projDir -Filter '*.json' -File |
                Where-Object { $_.Name -notmatch '\.bak-' } |
                ForEach-Object { $entries += Copy-Entry gemini $_.FullName }
        }
    } else {
        Write-Warning "$($Roots.gemini) not found - skipping Antigravity config."
    }

    [pscustomobject]@{
        exportedAt = (Get-Date).ToString('o')
        machine    = $env:COMPUTERNAME
        user       = $env:USERNAME
        roots      = @{ codex = '~\.codex'; gemini = '~\.gemini' }
        files      = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content $ManifestPath -Encoding utf8

    Write-Host "`n$($entries.Count) file(s) exported to $BackupRoot"
    Write-Host "Manifest: $ManifestPath"
    Write-Host "NOTE: config.toml embeds absolute C:\Users\<name> and Codex-app-version"
    Write-Host "paths (notify, [mcp_servers]) - see README-RESTORE.md before importing"
    Write-Host "onto a fresh install."
}
else {
    if (-not (Test-Path $ManifestPath)) { throw "manifest.json not found next to this script. Run -Mode Export first." }
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $restored = 0; $skipped = 0

    foreach ($e in $manifest.files) {
        $srcFile = Join-Path (Join-Path $BackupRoot $e.root) $e.rel
        $dest    = Join-Path $Roots[$e.root] $e.rel
        if (-not (Test-Path $srcFile)) {
            Write-Warning "missing in backup, skipped: [$($e.root)] $($e.rel)"
            $skipped++; continue
        }
        if ($WhatIfOnly) {
            Write-Host "would restore  $dest"
            continue
        }
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        if (Test-Path $dest) { Copy-Item $dest "$dest.pre-restore-$stamp" -Force }
        Copy-Item $srcFile $dest -Force
        Write-Host "restored  $dest"
        $restored++
    }
    if (-not $WhatIfOnly) {
        Write-Host "`n$restored file(s) restored, $skipped skipped."
        Write-Host "Next steps:"
        Write-Host " 1. Sign in to Codex again (auth.json was not backed up)."
        Write-Host " 2. Verify config.toml's notify/[mcp_servers] paths match the newly"
        Write-Host "    installed Codex app version (see README-RESTORE.md)."
        Write-Host " 3. For any NEW Antigravity workspace, run the bundled"
        Write-Host "    fix_antigravity_no_prompts.ps1 once so the fresh workspace GUID"
        Write-Host "    config gets the always-allow policies."
    }
}
