<#
.SYNOPSIS
Disable repeated Antigravity/Codex command approval prompts for this Windows user.

.DESCRIPTION
Applies the same no-prompts fixes used on this machine:

- C:\Users\<user>\.codex\config.toml
  - approval_policy = "never"
  - sandbox_mode = "danger-full-access"

- C:\Users\<user>\.gemini\config\config.json
  - global permission grants for unsandboxed commands, commands, reads, writes, URLs, and MCP

- C:\Users\<user>\.gemini\config\projects\outside-of-project.json and all projects\*.json
  - broad per-project grants (including all active and past workspace GUID configs)
  - eager execution / allow file access / turbo artifact review settings

The script is idempotent and creates timestamped .bak files before editing.
Restart Antigravity after running so its language server reloads the settings.
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
    Write-Host "[antigravity-no-prompts] $Message"
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

function New-JsonObject {
    return [ordered]@{}
}

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-Hashtable $InputObject[$key]
        }
        return $hash
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ConvertTo-Hashtable $item
        }
        return ,$items
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $hash[$property.Name] = ConvertTo-Hashtable $property.Value
        }
        return $hash
    }
    return $InputObject
}

function Add-Grants {
    param(
        [Parameter(Mandatory = $true)]$AllowList,
        [string[]]$RequiredGrants
    )

    $allow = @($AllowList)
    foreach ($grant in $RequiredGrants) {
        if ($allow -notcontains $grant) {
            $allow += $grant
        }
    }
    return $allow
}

function Read-JsonFileAsHashtable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$DefaultValue
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $DefaultValue
    }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultValue
    }

    return ConvertTo-Hashtable ($raw | ConvertFrom-Json)
}

function Ensure-GeminiGlobalConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredGrants
    )

    if ($VerifyOnly) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Step "Gemini global config missing: $Path"
            return
        }
        $raw = Get-Content -Raw -LiteralPath $Path
        foreach ($grant in $RequiredGrants) {
            Write-Step "Gemini global grant $grant present: $($raw.Contains($grant))"
        }
        Write-Step "Gemini global autoExecutionPolicy eager present: $($raw.Contains('CASCADE_COMMANDS_AUTO_EXECUTION_EAGER'))"
        Write-Step "Gemini global nonWorkspaceFileAccessPolicy allow present: $($raw.Contains('AGENT_SETTING_POLICY_ALLOW'))"
        Write-Step "Gemini global internetAccessPolicy allow present: $($raw.Contains('AGENT_SETTING_POLICY_ALLOW'))"
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $backup = Backup-File -Path $Path
    if ($backup) {
        Write-Step "backed up Gemini global config to $backup"
    }

    $cfg = Read-JsonFileAsHashtable -Path $Path -DefaultValue (New-JsonObject)
    if (-not $cfg.Contains("userSettings")) {
        $cfg["userSettings"] = New-JsonObject
    }
    if (-not $cfg["userSettings"].Contains("globalPermissionGrants")) {
        $cfg["userSettings"]["globalPermissionGrants"] = New-JsonObject
    }
    if (-not $cfg["userSettings"]["globalPermissionGrants"].Contains("allow")) {
        $cfg["userSettings"]["globalPermissionGrants"]["allow"] = @()
    }

    $cfg["userSettings"]["globalPermissionGrants"]["allow"] =
        Add-Grants -AllowList $cfg["userSettings"]["globalPermissionGrants"]["allow"] -RequiredGrants $RequiredGrants

    $cfg["userSettings"]["autoExecutionPolicy"] = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"
    $cfg["userSettings"]["artifactReviewMode"] = "ARTIFACT_REVIEW_MODE_TURBO"
    $cfg["userSettings"]["allowAgentAccessNonWorkspaceFiles"] = $true
    $cfg["userSettings"]["nonWorkspaceFileAccessPolicy"] = "AGENT_SETTING_POLICY_ALLOW"
    $cfg["userSettings"]["internetAccessPolicy"] = "AGENT_SETTING_POLICY_ALLOW"

    $cfg | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path
    Write-Step "updated Gemini global config: $Path"
}

function Ensure-GeminiProjectConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$RequiredGrants,
        [string]$DefaultId = "outside-of-project",
        [string]$DefaultName = "Outside of Project"
    )

    $fileName = Split-Path -Leaf $Path
    if ($VerifyOnly) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Step "Gemini project config missing: $Path"
            return
        }
        $raw = Get-Content -Raw -LiteralPath $Path
        foreach ($grant in $RequiredGrants) {
            Write-Step "Gemini project ($fileName) grant $grant present: $($raw.Contains($grant))"
        }
        Write-Step "Gemini project ($fileName) fileAccessPolicy allow present: $($raw.Contains('AGENT_SETTING_POLICY_ALLOW'))"
        Write-Step "Gemini project ($fileName) autoExecutionPolicy eager present: $($raw.Contains('CASCADE_COMMANDS_AUTO_EXECUTION_EAGER'))"
        Write-Step "Gemini project ($fileName) artifactReviewMode turbo present: $($raw.Contains('ARTIFACT_REVIEW_MODE_TURBO'))"
        Write-Step "Gemini project ($fileName) permissionPreset turbo present: $($raw.Contains('AGENT_PERMISSION_PRESET_TURBO'))"
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $Path)
    $backup = Backup-File -Path $Path
    if ($backup) {
        Write-Step "backed up Gemini project config ($fileName) to $backup"
    }

    $default = [ordered]@{
        id = $DefaultId
        name = $DefaultName
        permissionGrants = [ordered]@{
            permissionGrants = [ordered]@{
                allow = @()
            }
        }
        settings = [ordered]@{}
    }
    $cfg = Read-JsonFileAsHashtable -Path $Path -DefaultValue $default

    if (-not $cfg.Contains("permissionGrants")) {
        $cfg["permissionGrants"] = New-JsonObject
    }
    if (-not $cfg["permissionGrants"].Contains("permissionGrants")) {
        $cfg["permissionGrants"]["permissionGrants"] = New-JsonObject
    }
    if (-not $cfg["permissionGrants"]["permissionGrants"].Contains("allow")) {
        $cfg["permissionGrants"]["permissionGrants"]["allow"] = @()
    }
    if (-not $cfg.Contains("settings")) {
        $cfg["settings"] = New-JsonObject
    }

    $cfg["permissionGrants"]["permissionGrants"]["allow"] =
        Add-Grants -AllowList $cfg["permissionGrants"]["permissionGrants"]["allow"] -RequiredGrants $RequiredGrants
    $cfg["settings"]["fileAccessPolicy"] = "AGENT_SETTING_POLICY_ALLOW"
    $cfg["settings"]["internetPolicy"] = "AGENT_SETTING_POLICY_ALLOW"
    $cfg["settings"]["autoExecutionPolicy"] = "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"
    $cfg["settings"]["artifactReviewMode"] = "ARTIFACT_REVIEW_MODE_TURBO"
    $cfg["settings"]["permissionPreset"] = "AGENT_PERMISSION_PRESET_TURBO"

    # Ensure projectResources.resources is an array if present
    if ($cfg.Contains("projectResources") -and $cfg["projectResources"].Contains("resources")) {
        if ($cfg["projectResources"]["resources"] -isnot [System.Collections.IEnumerable] -or $cfg["projectResources"]["resources"] -is [string]) {
            $cfg["projectResources"]["resources"] = ,@($cfg["projectResources"]["resources"])
        }
    }

    $cfg | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $Path
    Write-Step "updated Gemini project config: $Path"
}

$requiredGrants = @(
    "unsandboxed(*)",
    "command(*)",
    "read_file(*)",
    "write_file(*)",
    "read_url(*)",
    "mcp(*)"
)

$codexConfig = Join-Path $UserHome ".codex\config.toml"
$geminiConfig = Join-Path $UserHome ".gemini\config\config.json"
$projectsDir = Join-Path $UserHome ".gemini\config\projects"
$outsideProjectConfig = Join-Path $projectsDir "outside-of-project.json"

Write-Step "user home: $UserHome"
Ensure-CodexConfig -Path $codexConfig
Ensure-GeminiGlobalConfig -Path $geminiConfig -RequiredGrants $requiredGrants
Ensure-Directory -Path $projectsDir

# Update outside-of-project config
Ensure-GeminiProjectConfig -Path $outsideProjectConfig -RequiredGrants $requiredGrants -DefaultId "outside-of-project" -DefaultName "Outside of Project"

# Update all existing workspace project GUID configs
$projectFiles = Get-ChildItem -Path $projectsDir -Filter "*.json" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "outside-of-project.json" }
foreach ($file in $projectFiles) {
    Ensure-GeminiProjectConfig -Path $file.FullName -RequiredGrants $requiredGrants -DefaultId ([System.IO.Path]::GetFileNameWithoutExtension($file.Name)) -DefaultName $file.BaseName
}

if (-not $VerifyOnly) {
    Write-Step "done. Fully restart Antigravity so the language server reloads these settings."
}
