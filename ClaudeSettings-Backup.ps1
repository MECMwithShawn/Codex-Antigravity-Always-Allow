<#
.SYNOPSIS
  Export / import Claude Code permission & settings files.

.DESCRIPTION
  Export mode: snapshots all Claude Code settings files (user-level and
  project-level) into .\settings\ next to this script, plus a manifest.json
  that records where each file came from.

  Import mode: reads manifest.json and copies each file back to its original
  location (with $HOME re-resolved, so it works even if the username/drive
  layout changed). Existing destination files are backed up with a
  .pre-restore timestamp suffix before being overwritten.

  NEVER exports ~/.claude/.credentials.json (auth tokens do not belong in
  OneDrive; you re-login with `claude` after an OS reload).

.EXAMPLE
  .\ClaudeSettings-Backup.ps1 -Mode Export
  .\ClaudeSettings-Backup.ps1 -Mode Import
  .\ClaudeSettings-Backup.ps1 -Mode Import -WhatIfOnly   # dry run
#>
param(
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Mode,
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$BackupRoot   = Join-Path $PSScriptRoot 'settings'
$ManifestPath = Join-Path $PSScriptRoot 'manifest.json'

# Roots scanned for project-level .claude\settings*.json during export.
$ScanRoots = @(
    (Join-Path $HOME 'Documents'),
    (Join-Path $HOME 'Downloads'),
    (Join-Path $HOME 'OneDrive')
)
# Paths containing these segments are skipped (third-party / transient copies).
$ExcludePatterns = @('\node_modules\', '\.claude\worktrees\')

function Get-PortablePath([string]$AbsPath) {
    # Store paths relative to $HOME when possible so import survives a
    # username change.
    if ($AbsPath.StartsWith($HOME, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $AbsPath.Substring($HOME.Length)
    }
    return $AbsPath
}
function Resolve-PortablePath([string]$Portable) {
    if ($Portable.StartsWith('~')) { return $HOME + $Portable.Substring(1) }
    return $Portable
}

if ($Mode -eq 'Export') {
    $sources = New-Object System.Collections.Generic.List[string]

    # 1. User-level: global permissions + config (per-project allowed tools,
    #    MCP servers, theme, etc.). Credentials file intentionally excluded.
    foreach ($f in @(
        (Join-Path $HOME '.claude\settings.json'),
        (Join-Path $HOME '.claude.json')
    )) { if (Test-Path $f) { $sources.Add($f) } }
    # Hook scripts the settings point at (e.g. auto_continue.py).
    $userHooks = Join-Path $HOME '.claude\hooks'
    if (Test-Path $userHooks) {
        Get-ChildItem $userHooks -File | ForEach-Object { $sources.Add($_.FullName) }
    }

    # 2. Project-level settings under the scan roots.
    foreach ($root in $ScanRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -Directory -Filter '.claude' -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem $_.FullName -Filter 'settings*.json' -File -ErrorAction SilentlyContinue
                $hooks = Join-Path $_.FullName 'hooks'
                if (Test-Path $hooks) { Get-ChildItem $hooks -File -ErrorAction SilentlyContinue }
            } |
            Where-Object {
                $p = $_.FullName
                -not ($ExcludePatterns | Where-Object { $p -like "*$_*" })
            } |
            ForEach-Object { $sources.Add($_.FullName) }
    }

    $sources = $sources | Sort-Object -Unique

    if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    $entries = @()
    $i = 0
    foreach ($src in $sources) {
        $i++
        # Flat store: 001_settings.json style, original path kept in manifest.
        $leaf  = Split-Path $src -Leaf
        $store = '{0:d3}_{1}' -f $i, $leaf
        Copy-Item $src (Join-Path $BackupRoot $store) -Force
        $entries += [pscustomobject]@{
            store    = $store
            original = Get-PortablePath $src
        }
        Write-Host "exported  $src"
    }

    [pscustomobject]@{
        exportedAt = (Get-Date).ToString('o')
        machine    = $env:COMPUTERNAME
        user       = $env:USERNAME
        files      = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content $ManifestPath -Encoding utf8

    Write-Host "`n$($entries.Count) file(s) exported to $BackupRoot"
    Write-Host "Manifest: $ManifestPath"
}
else {
    if (-not (Test-Path $ManifestPath)) { throw "manifest.json not found next to this script. Run -Mode Export first." }
    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $restored = 0; $skipped = 0

    foreach ($e in $manifest.files) {
        $srcFile = Join-Path $BackupRoot $e.store
        $dest    = Resolve-PortablePath $e.original
        if (-not (Test-Path $srcFile)) {
            Write-Warning "missing in backup, skipped: $($e.store)"
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
        Write-Host "Note: run 'claude' once to log in again - credentials were not backed up."
    }
}
