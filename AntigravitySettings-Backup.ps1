<#
.SYNOPSIS
  Export / import Antigravity / Gemini Code permission & settings files (~/.gemini).

.DESCRIPTION
  Export mode: snapshots Antigravity and Gemini Code permission-relevant configuration
  into .\settings\ next to this script, plus a manifest.json recording original locations:
    - config\config.json        (globalPermissionGrants, unsandboxed/command/read/write allowlists)
    - config\projects\*.json    (per-project and outside-of-project permission exceptions)
    - GEMINI.md                 (global agent rules and instructions)
    - config\GEMINI.md          (global configuration rules)
    - settings.json             (MCP servers e.g. Supabase, global settings)
    - config\mcp_config.json    (MCP server declarations)
    - config\.migrated          (migration marker flag)
    - antigravity\antigravity_state.pbtxt (onboarding and migration state flags)

  Import mode: restores configuration files to ~/.gemini on the current machine,
  backing up any existing destination files as *.pre-restore-<timestamp> first.
  If the username or user profile path changed, paths in permission grants are
  automatically adapted.

  NEVER exports session transcripts, brain caches, conversation history, or crash dumps.

.EXAMPLE
  .\AntigravitySettings-Backup.ps1 -Mode Export
  .\AntigravitySettings-Backup.ps1 -Mode Import
  .\AntigravitySettings-Backup.ps1 -Mode Import -WhatIfOnly   # dry run
#>
param(
    [Parameter(Mandatory)][ValidateSet('Export','Import')][string]$Mode,
    [switch]$WhatIfOnly,
    [switch]$RemapUser
)

$ErrorActionPreference = 'Stop'
$GeminiHome   = Join-Path $HOME '.gemini'
$BackupRoot   = Join-Path $PSScriptRoot 'settings'
$ManifestPath = Join-Path $PSScriptRoot 'manifest.json'

# Exact files and directories relative to ~/.gemini to capture
$SingleFiles = @(
    'GEMINI.md',
    'settings.json',
    'config\config.json',
    'config\GEMINI.md',
    'config\mcp_config.json',
    'config\.migrated',
    'antigravity\antigravity_state.pbtxt'
)

$Dirs = @(
    'config\skills',
    'config\sidecars'
)

if ($Mode -eq 'Export') {
    if (-not (Test-Path $GeminiHome)) {
        throw "$GeminiHome not found. Is Antigravity / Gemini Code installed for this user?"
    }

    if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    $entries = @()

    $addFile = {
        param($AbsPath)
        $rel = $AbsPath.Substring($GeminiHome.Length).TrimStart('\')
        $dest = Join-Path $BackupRoot $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item $AbsPath $dest -Force
        Write-Host "exported  $rel"
        $rel
    }

    # 1. Capture single key configuration files
    foreach ($f in $SingleFiles) {
        $fullPath = Join-Path $GeminiHome $f
        if (Test-Path $fullPath) {
            $entries += & $addFile $fullPath
        }
    }

    # 2. Capture project permission files (exclude backup copies like *.bak-*)
    $projectsDir = Join-Path $GeminiHome 'config\projects'
    if (Test-Path $projectsDir) {
        Get-ChildItem -Path $projectsDir -Filter '*.json' -File |
            Where-Object { $_.Name -notmatch '\.bak-' } |
            ForEach-Object {
                $entries += & $addFile $_.FullName
            }
    }

    # 3. Capture any custom directories (skills, sidecars)
    foreach ($d in $Dirs) {
        $dirPath = Join-Path $GeminiHome $d
        if (Test-Path $dirPath) {
            Get-ChildItem $dirPath -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $entries += & $addFile $_.FullName }
        }
    }

    [pscustomobject]@{
        exportedAt  = (Get-Date).ToString('o')
        machine     = $env:COMPUTERNAME
        user        = $env:USERNAME
        userProfile = $env:USERPROFILE
        geminiHome  = '~\.gemini'
        files       = $entries
    } | ConvertTo-Json -Depth 5 | Set-Content $ManifestPath -Encoding utf8

    Write-Host "`n$($entries.Count) file(s) exported to $BackupRoot"
    Write-Host "Manifest: $ManifestPath"
}
else {
    if (-not (Test-Path $ManifestPath)) {
        throw "manifest.json not found next to this script. Run -Mode Export first."
    }

    $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $restored = 0
    $skipped = 0

    $oldUser = $manifest.user
    $currentUser = $env:USERNAME
    $needUserRemap = ($RemapUser -or ($oldUser -and ($oldUser -ne $currentUser)))

    foreach ($rel in $manifest.files) {
        $srcFile = Join-Path $BackupRoot $rel
        $dest = Join-Path $GeminiHome $rel

        if (-not (Test-Path $srcFile)) {
            Write-Warning "missing in backup, skipped: $rel"
            $skipped++
            continue
        }

        if ($WhatIfOnly) {
            Write-Host "would restore  $dest"
            continue
        }

        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }

        if (Test-Path $dest) {
            Copy-Item $dest "$dest.pre-restore-$stamp" -Force
        }

        if ($needUserRemap -and ($rel -match '\.json$')) {
            # Remap paths inside JSON configs if username changed
            $content = Get-Content $srcFile -Raw
            $oldProfileEscaped = [regex]::Escape("C:\Users\$oldUser")
            $newProfile = "C:\Users\$currentUser"
            $content = [regex]::Replace($content, $oldProfileEscaped, $newProfile, 'IgnoreCase')

            $oldUriEscaped = [regex]::Escape("Users/$oldUser")
            $newUri = "Users/$currentUser"
            $content = [regex]::Replace($content, $oldUriEscaped, $newUri, 'IgnoreCase')

            Set-Content -Path $dest -Value $content -Encoding utf8
        }
        else {
            Copy-Item $srcFile $dest -Force
        }

        Write-Host "restored  $dest"
        $restored++
    }

    if (-not $WhatIfOnly) {
        Write-Host "`n$restored file(s) restored, $skipped skipped."
        if ($needUserRemap) {
            Write-Host "Note: Username path remapping applied ($oldUser -> $currentUser)."
        }
        Write-Host "Restart Antigravity / Gemini Code to apply restored settings."
    }
}
