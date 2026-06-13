[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Codex,
    [switch]$Claude,
    [string]$Project = (Get-Location).Path,
    [switch]$Replace,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
Usage: .\install.ps1 [-All|-Codex|-Claude] [-Project PATH] [-Replace] [-DryRun]

Options:
  -All       Install Codex + Claude settings (default)
  -Codex     Install Codex settings only
  -Claude    Install Claude settings only
  -Project   Target project for .claude/settings.json (default: current directory)
  -Replace   Replace Antigravity settings file instead of merge
  -DryRun    Print actions without writing files
  -Help      Show this help

Examples:
  .\install.ps1 -All -Project C:\code\my-repo
  .\install.ps1 -Codex
  .\install.ps1 -Claude -Project C:\code\my-repo
"@
}

function Write-Log {
    param([string]$Message)
    Write-Host $Message
}

function Backup-File {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$Path.bak.$timestamp"
    if ($DryRun) {
        Write-Log "[dry-run] backup $Path -> $backupPath"
        return
    }

    Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    Write-Log "Backed up: $backupPath"
}

function Copy-File {
    param(
        [string]$Source,
        [string]$Destination
    )

    $destinationDir = [System.IO.Path]::GetDirectoryName($Destination)
    if ($DryRun) {
        Write-Log "[dry-run] mkdir -p $destinationDir"
        Write-Log "[dry-run] copy $Source -> $Destination"
        return
    }

    if (-not (Test-Path -LiteralPath $destinationDir)) {
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Log "Wrote: $Destination"
}

function Convert-ToMergeObject {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = Convert-ToMergeObject $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $Value.PSObject.Properties) {
            $result[$prop.Name] = Convert-ToMergeObject $prop.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @($Value | ForEach-Object { Convert-ToMergeObject $_ })
        return ,$items
    }

    return $Value
}

function Normalize-JsonText {
    param([string]$JsonText)

    $withoutBlockComments = [regex]::Replace($JsonText, "/\*[\s\S]*?\*/", "")
    $withoutLineComments = [regex]::Replace($withoutBlockComments, "(?m)^\s*//.*$", "")
    $withoutTrailingCommas = [regex]::Replace($withoutLineComments, ",(\s*[}\]])", '$1')
    return $withoutTrailingCommas
}

function Parse-JsonLikeFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    try {
        return Convert-ToMergeObject ($raw | ConvertFrom-Json)
    } catch {
        $normalized = Normalize-JsonText $raw
        return Convert-ToMergeObject ($normalized | ConvertFrom-Json)
    }
}

function Merge-Hashtable {
    param(
        [hashtable]$Base,
        [hashtable]$Overlay
    )

    foreach ($key in $Overlay.Keys) {
        $overlayValue = $Overlay[$key]
        if (
            $Base.ContainsKey($key) -and
            ($Base[$key] -is [hashtable]) -and
            ($overlayValue -is [hashtable])
        ) {
            Merge-Hashtable -Base $Base[$key] -Overlay $overlayValue | Out-Null
            continue
        }

        $Base[$key] = $overlayValue
    }

    return $Base
}

function Write-TextFileWithRetry {
    param(
        [string]$Path,
        [string]$Content
    )

    $attempts = 12
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            $Content | Set-Content -LiteralPath $Path -Encoding utf8
            return
        } catch [System.IO.IOException] {
            if ($i -ge $attempts) {
                throw
            }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Merge-JsonIntoFile {
    param(
        [string]$BaseFile,
        [string]$OverlayFile
    )

    if ($Replace) {
        Backup-File -Path $BaseFile
        Copy-File -Source $OverlayFile -Destination $BaseFile
        return
    }

    if ($DryRun) {
        Write-Log "[dry-run] merge JSON: $BaseFile + $OverlayFile"
        return
    }

    $baseDir = [System.IO.Path]::GetDirectoryName($BaseFile)
    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $BaseFile -PathType Leaf)) {
        Write-TextFileWithRetry -Path $BaseFile -Content "{}"
    }

    Backup-File -Path $BaseFile
    $baseObj = Parse-JsonLikeFile -Path $BaseFile
    $overlayObj = Parse-JsonLikeFile -Path $OverlayFile
    $merged = Merge-Hashtable -Base $baseObj -Overlay $overlayObj
    Write-TextFileWithRetry -Path $BaseFile -Content ($merged | ConvertTo-Json -Depth 100)
    Write-Log "Merged: $BaseFile"
}

function Reset-AgentPreferenceMigrationFlags {
    param([string]$StorageFile)

    if ($DryRun) {
        Write-Log "[dry-run] reset one-time agent preference migration flags in $StorageFile"
        return
    }

    if (-not (Test-Path -LiteralPath $StorageFile -PathType Leaf)) {
        return
    }

    Backup-File -Path $StorageFile
    $storage = Parse-JsonLikeFile -Path $StorageFile

    $storage["antigravityUnifiedStateSync.agentPreferences.hasPlanningModeMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasArtifactReviewPolicyMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasTerminalAutoExecutionPolicyMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasTerminalAllowedCommandsMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasTerminalDeniedCommandsMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasAgentFileAccessMigration"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasExplainAndFixInCurrentConversationMigrated"] = $false
    $storage["antigravityUnifiedStateSync.agentPreferences.hasAutoContinueOnMaxGeneratorInvocationsMigrated"] = $false

    Write-TextFileWithRetry -Path $StorageFile -Content ($storage | ConvertTo-Json -Depth 100)
    Write-Log "Updated: $StorageFile (agent preference migration flags reset)"
}

function Find-AntigravityAutoAcceptExtensionRoot {
    $extensionsDir = Join-Path $env:USERPROFILE ".antigravity\extensions"
    if (-not (Test-Path -LiteralPath $extensionsDir -PathType Container)) {
        return $null
    }

    return Get-ChildItem -LiteralPath $extensionsDir -Directory -Filter "pesosz.antigravity-auto-accept-*" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Apply-ExactTextPatches {
    param(
        [string]$Path,
        [object[]]$Patches
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Log "Skipped missing file: $Path"
        return
    }

    $content = Get-Content -Raw -LiteralPath $Path
    $updated = $content
    $appliedLabels = @()

    foreach ($patch in $Patches) {
        $label = [string]$patch.Label
        $search = [string]$patch.Search
        $replacement = [string]$patch.Replacement

        if ($updated.Contains($replacement)) {
            Write-Log "Already patched: $label"
            continue
        }

        if (-not $updated.Contains($search)) {
            Write-Log "Skipped patch (pattern not found): $label"
            continue
        }

        $updated = $updated.Replace($search, $replacement)
        $appliedLabels += $label
    }

    if ($appliedLabels.Count -eq 0) {
        return
    }

    Backup-File -Path $Path
    if ($DryRun) {
        foreach ($label in $appliedLabels) {
            Write-Log "[dry-run] patch $label in $Path"
        }
        return
    }

    Write-TextFileWithRetry -Path $Path -Content $updated
    Write-Log "Patched: $Path"
}

function Patch-AntigravityAutoAcceptExtension {
    $extensionRoot = Find-AntigravityAutoAcceptExtensionRoot
    if ($null -eq $extensionRoot) {
        Write-Log "Antigravity Auto Accept extension not found. Skipping extension patch."
        return
    }

    Write-Log ""
    Write-Log "Patching Antigravity Auto Accept extension..."

    $extensionJsPath = Join-Path $extensionRoot.FullName "extension.js"
    $distExtensionJsPath = Join-Path $extensionRoot.FullName "dist\extension.js"
    $autoAcceptJsPath = Join-Path $extensionRoot.FullName "main_scripts\auto-accept.js"

    $extensionAcceptCommandsSearch = @"
const ACCEPT_COMMANDS_ANTIGRAVITY = [
    'antigravity.command.accept',
    'antigravity.agent.acceptAgentStep',
    'antigravity.interactiveCascade.acceptSuggestedAction',
    'antigravity.terminalCommand.accept',
    'antigravity.terminalCommand.run',
    'antigravity.executeCascadeAction',
    'antigravity.command.continue',
    'antigravity.agent.continue',
    'antigravity.command.continueGenerating',
    'antigravity.continueGenerating',
    'antigravity.command.alwaysAllow',
    'antigravity.agent.alwaysAllow',
    'antigravity.permission.alwaysAllow',
    'antigravity.browser.alwaysAllow',
    'antigravity.command.allowOnce',
    'antigravity.permission.allowOnce',
    'antigravity.agent.allowOnce'
];
"@

    $extensionAcceptCommandsReplacement = @"
const ACCEPT_COMMANDS_ANTIGRAVITY = [
    'antigravity.command.accept',
    'antigravity.agent.acceptAgentStep',
    'antigravity.interactiveCascade.acceptSuggestedAction',
    'antigravity.terminalCommand.accept',
    'antigravity.terminalCommand.run',
    'antigravity.executeCascadeAction',
    'antigravity.command.continue',
    'antigravity.agent.continue',
    'antigravity.command.continueGenerating',
    'antigravity.continueGenerating',
    'antigravity.command.alwaysAllow',
    'antigravity.agent.alwaysAllow',
    'antigravity.permission.alwaysAllow',
    'antigravity.browser.alwaysAllow',
    'antigravity.command.allowOnce',
    'antigravity.permission.allowOnce',
    'antigravity.agent.allowOnce'
];

const ANTIGRAVITY_FILE_ACCEPT_COMMANDS = [
    'antigravity.prioritized.agentAcceptAllInFile',
    'antigravity.prioritized.agentAcceptFocusedHunk'
];
"@

    $extensionExecuteSearch = @"
async function executeAcceptCommandsForIDE() {
    const ide = (currentIDE || '').toLowerCase();
    if (ide === 'antigravity') {
        // Safety hardening: do not execute global Antigravity commands from poll loop.
        // Approvals should happen only via prompt-scoped CDP DOM handling.
        return;
    }

    const commands = [...new Set([...getAcceptCommandsForIDE(), ...runtimeSafeCommands])];
"@

    $extensionExecuteReplacement = @"
async function executeAcceptCommandsForIDE() {
    const ide = (currentIDE || '').toLowerCase();
    if (ide === 'antigravity') {
        const commands = [...new Set([
            ...ANTIGRAVITY_FILE_ACCEPT_COMMANDS,
            ...antigravityDiscoveredCommands.filter(cmd => {
                const c = (cmd || '').toLowerCase();
                return c.includes('agentacceptallinfile') || c.includes('agentacceptfocusedhunk');
            })
        ])];

        if (commands.length === 0) return;
        await Promise.allSettled(commands.map(cmd => vscode.commands.executeCommand(cmd)));
        return;
    }

    const commands = [...new Set([...getAcceptCommandsForIDE(), ...runtimeSafeCommands])];
"@

    Apply-ExactTextPatches -Path $extensionJsPath -Patches @(
        @{
            Label = "extension.js accept command constant"
            Search = $extensionAcceptCommandsSearch
            Replacement = $extensionAcceptCommandsReplacement
        },
        @{
            Label = "extension.js Antigravity command execution"
            Search = $extensionExecuteSearch
            Replacement = $extensionExecuteReplacement
        }
    )

    $distAcceptCommandsSearch = @"
var ACCEPT_COMMANDS_ANTIGRAVITY = [
  "antigravity.command.accept",
  "antigravity.agent.acceptAgentStep",
  "antigravity.interactiveCascade.acceptSuggestedAction",
  "antigravity.terminalCommand.accept",
  "antigravity.terminalCommand.run",
  "antigravity.executeCascadeAction",
  "antigravity.command.continue",
  "antigravity.agent.continue",
  "antigravity.command.continueGenerating",
  "antigravity.continueGenerating",
  "antigravity.command.alwaysAllow",
  "antigravity.agent.alwaysAllow",
  "antigravity.permission.alwaysAllow",
  "antigravity.browser.alwaysAllow",
  "antigravity.command.allowOnce",
  "antigravity.permission.allowOnce",
  "antigravity.agent.allowOnce"
];
"@

    $distAcceptCommandsReplacement = @"
var ACCEPT_COMMANDS_ANTIGRAVITY = [
  "antigravity.command.accept",
  "antigravity.agent.acceptAgentStep",
  "antigravity.interactiveCascade.acceptSuggestedAction",
  "antigravity.terminalCommand.accept",
  "antigravity.terminalCommand.run",
  "antigravity.executeCascadeAction",
  "antigravity.command.continue",
  "antigravity.agent.continue",
  "antigravity.command.continueGenerating",
  "antigravity.continueGenerating",
  "antigravity.command.alwaysAllow",
  "antigravity.agent.alwaysAllow",
  "antigravity.permission.alwaysAllow",
  "antigravity.browser.alwaysAllow",
  "antigravity.command.allowOnce",
  "antigravity.permission.allowOnce",
  "antigravity.agent.allowOnce"
];
var ANTIGRAVITY_FILE_ACCEPT_COMMANDS = [
  "antigravity.prioritized.agentAcceptAllInFile",
  "antigravity.prioritized.agentAcceptFocusedHunk"
];
"@

    $distExecuteSearch = @"
async function executeAcceptCommandsForIDE() {
  const ide = (currentIDE || "").toLowerCase();
  if (ide === "antigravity") {
    return;
  }
  const commands = [.../* @__PURE__ */ new Set([...getAcceptCommandsForIDE(), ...runtimeSafeCommands])];
"@

    $distExecuteReplacement = @"
async function executeAcceptCommandsForIDE() {
  const ide = (currentIDE || "").toLowerCase();
  if (ide === "antigravity") {
    const commands2 = [.../* @__PURE__ */ new Set([
      ...ANTIGRAVITY_FILE_ACCEPT_COMMANDS,
      ...antigravityDiscoveredCommands.filter((cmd) => {
        const c = (cmd || "").toLowerCase();
        return c.includes("agentacceptallinfile") || c.includes("agentacceptfocusedhunk");
      })
    ])];
    if (commands2.length === 0)
      return;
    await Promise.allSettled(commands2.map((cmd) => vscode.commands.executeCommand(cmd)));
    return;
  }
  const commands = [.../* @__PURE__ */ new Set([...getAcceptCommandsForIDE(), ...runtimeSafeCommands])];
"@

    Apply-ExactTextPatches -Path $distExtensionJsPath -Patches @(
        @{
            Label = "dist/extension.js accept command constant"
            Search = $distAcceptCommandsSearch
            Replacement = $distAcceptCommandsReplacement
        },
        @{
            Label = "dist/extension.js Antigravity command execution"
            Search = $distExecuteSearch
            Replacement = $distExecuteReplacement
        }
    )

    $autoAcceptBypassSearch = "                const bypassExclude = reason === 'run-prompt';"
    $autoAcceptBypassReplacement = "                const bypassExclude = reason === 'run-prompt' || reason === 'file-edit';"

    $autoAcceptPermissionSearch = @"
                    if (reason === 'permission') {
                        const state = window.__autoAcceptFreeState || {};
                        state.lastPermissionClickAt = now;
                        state.lastPermissionX = rect.left + (rect.width / 2);
                        state.lastPermissionY = rect.top + (rect.height / 2);
                        state.permissionApprovals = (state.permissionApprovals || 0) + 1;
                        window.__autoAcceptFreeState = state;

                        const origin = el.closest('[role="dialog"], .notification-toast, .notification-list-item, .monaco-dialog-box, .monaco-dialog-modal-block, .chat-tool-call, .chat-tool-response, [class*="tool-call"], [data-testid*="tool-call"]');
                        if (origin && origin.setAttribute) {
                            origin.setAttribute('data-aaf-permission-origin-at', String(now));
                        }
                    }
"@

    $autoAcceptPermissionReplacement = @"
                    if (reason === 'permission') {
                        const state = window.__autoAcceptFreeState || {};
                        state.lastPermissionClickAt = now;
                        state.lastPermissionX = rect.left + (rect.width / 2);
                        state.lastPermissionY = rect.top + (rect.height / 2);
                        state.permissionApprovals = (state.permissionApprovals || 0) + 1;
                        window.__autoAcceptFreeState = state;

                        const origin = el.closest('[role="dialog"], .notification-toast, .notification-list-item, .monaco-dialog-box, .monaco-dialog-modal-block, .chat-tool-call, .chat-tool-response, [class*="tool-call"], [data-testid*="tool-call"]');
                        if (origin && origin.setAttribute) {
                            origin.setAttribute('data-aaf-permission-origin-at', String(now));
                        }
                    } else if (reason === 'file-edit') {
                        const state = window.__autoAcceptFreeState || {};
                        state.fileEdits = (state.fileEdits || 0) + 1;
                        window.__autoAcceptFreeState = state;
                    }
"@

    $autoAcceptFileReviewSearch = @'
        // Hard-disable broad generic auto-click fallback to prevent random IDE clicks.
        // Remaining logic already handles explicit command/permission/recovery prompts above.
        return clickedCount;
'@

    $autoAcceptFileReviewReplacement = @'
        // 1.7) File review actions (Accept all / Accept) in the agent review row
        const findFileReviewContext = (btn) => {
            let node = btn;
            let depth = 0;
            while (node && depth < 12) {
                try {
                    const contextText = String(node.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
                    const neighbors = Array.from(node.querySelectorAll(ACTION_NODE_SELECTOR));
                    const hasAcceptAction = neighbors.some(el => /\baccept(\s+all)?\b/i.test(getActionText(el)));
                    const hasRejectAction = neighbors.some(el => /\breject(\s+all)?\b/i.test(getActionText(el)));
                    const hasFileMarker =
                        /\b\d+\s+file(?:s)?\s+with\s+changes\b/i.test(contextText) ||
                        contextText.includes('file with changes');
                    const hasDiffMarker =
                        /(^|\s)[+-]\d+(\s|$)/.test(contextText) ||
                        /[a-z]:\\|\/.+\.[a-z0-9]{1,8}\b/i.test(contextText);

                    if ((hasAcceptAction && hasRejectAction && hasFileMarker) || (hasFileMarker && hasDiffMarker)) {
                        return node;
                    }
                } catch (e) { }

                node = node.parentElement;
                depth++;
            }

            return null;
        };

        const fileEditCandidates = [];
        for (const btn of queryAll(ACTION_NODE_SELECTOR)) {
            const text = getActionText(btn);
            if (!text) continue;
            if (/\breject\b|\bcancel\b|\bdeny\b|\bdiscard\b/i.test(text)) continue;
            if (!/\baccept(\s+all)?\b|\bapply(\s+all)?\b|\bkeep\b/i.test(text)) continue;

            const container = findFileReviewContext(btn);
            if (!container) continue;

            const containerText = String(container.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase();
            let score = 0;
            if (/\baccept all\b/i.test(text)) score += 10;
            else if (/\baccept\b/i.test(text)) score += 5;
            if (/\b\d+\s+file(?:s)?\s+with\s+changes\b/i.test(containerText)) score += 10;
            if (containerText.includes('file with changes')) score += 6;
            if (containerText.includes('reject all')) score += 4;
            if (/(^|\s)[+-]\d+(\s|$)/.test(containerText)) score += 2;

            fileEditCandidates.push({ btn, text, score });
        }

        if (fileEditCandidates.length > 0) {
            fileEditCandidates.sort((a, b) => b.score - a.score);
            const best = fileEditCandidates[0];
            if (clickElement(best.btn, 'file-edit')) {
                log(`File review accepted automatically: "${best.text}" (score=${best.score})`);
                return clickedCount;
            }
        }

        // Hard-disable broad generic auto-click fallback to prevent random IDE clicks.
        // Remaining logic already handles explicit command/permission/recovery prompts above.
        return clickedCount;
'@

    Apply-ExactTextPatches -Path $autoAcceptJsPath -Patches @(
        @{
            Label = "main_scripts/auto-accept.js file-edit bypass"
            Search = $autoAcceptBypassSearch
            Replacement = $autoAcceptBypassReplacement
        },
        @{
            Label = "main_scripts/auto-accept.js file-edit counter"
            Search = $autoAcceptPermissionSearch
            Replacement = $autoAcceptPermissionReplacement
        },
        @{
            Label = "main_scripts/auto-accept.js file review auto-accept"
            Search = $autoAcceptFileReviewSearch
            Replacement = $autoAcceptFileReviewReplacement
        },
        @{
            Label = "main_scripts/auto-accept.js state.fileEdits"
            Search = @'
        window.__autoAcceptFreeState = {
            isRunning: false,
            sessionID: 0,
            clicks: 0,
            lastRunShortcutAt: 0,
'@
            Replacement = @'
        window.__autoAcceptFreeState = {
            isRunning: false,
            sessionID: 0,
            clicks: 0,
            fileEdits: 0,
            lastRunShortcutAt: 0,
'@
        },
        @{
            Label = "main_scripts/auto-accept.js stats.fileEdits"
            Search = @'
        return { 
            clicks: window.__autoAcceptFreeState.clicks || 0,
            tabCount: window.__autoAcceptFreeState.tabNames?.length || 0,
'@
            Replacement = @'
        return { 
            clicks: window.__autoAcceptFreeState.clicks || 0,
            fileEdits: window.__autoAcceptFreeState.fileEdits || 0,
            tabCount: window.__autoAcceptFreeState.tabNames?.length || 0,
'@
        },
        @{
            Label = "main_scripts/auto-accept.js reset fileEdits"
            Search = @'
        state.bannedCommands = config.bannedCommands || [];
        state.tabNames = [];
        state.lastRunShortcutAt = 0;
'@
            Replacement = @'
        state.bannedCommands = config.bannedCommands || [];
        state.tabNames = [];
        state.fileEdits = 0;
        state.lastRunShortcutAt = 0;
'@
        }
    )
}

function Apply-AntigravityAlwaysAllowState {
    $stateScript = Join-Path $scriptDir "Set-AntigravityAlwaysAllow.ps1"
    if (-not (Test-Path -LiteralPath $stateScript -PathType Leaf)) {
        Write-Log "Set-AntigravityAlwaysAllow.ps1 not found. Skipping Antigravity state patch."
        return
    }

    Write-Log ""
    Write-Log "Applying Antigravity Always Allow state..."

    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $stateScript)
    if ($DryRun) {
        $args += "-DryRun"
    }

    & powershell @args
    if ($LASTEXITCODE -ne 0) {
        throw "Set-AntigravityAlwaysAllow.ps1 failed with exit code $LASTEXITCODE"
    }
}

if ($Help) {
    Show-Usage
    exit 0
}

$selectedModes = @()
if ($All) { $selectedModes += "all" }
if ($Codex) { $selectedModes += "codex" }
if ($Claude) { $selectedModes += "claude" }
if ($selectedModes.Count -gt 1) {
    throw "Choose only one of: -All, -Codex, -Claude"
}
$Mode = if ($selectedModes.Count -eq 0) { "all" } else { $selectedModes[0] }

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$codexTomlSrc = Join-Path $scriptDir "codex-no-prompts\codex-config.toml"
$codexAgSettingsSrc = Join-Path $scriptDir "codex-no-prompts\antigravity-settings.json"
$claudeAgSettingsSrc = Join-Path $scriptDir "claude-opus-4.6-no-prompts\antigravity-claude-settings.json"
$claudeProjectSettingsSrc = Join-Path $scriptDir "claude-opus-4.6-no-prompts\claude-code-settings.json"

$codexTomlDst = Join-Path $env:USERPROFILE ".codex\config.toml"
$agUserDir = Join-Path $env:APPDATA "Antigravity\User"
$agSettingsDst = Join-Path $agUserDir "settings.json"
$agStorageDst = Join-Path $agUserDir "globalStorage\storage.json"
$claudeProjectSettingsDst = Join-Path $Project ".claude\settings.json"
$claudeGlobalSettingsDst = Join-Path $env:USERPROFILE ".claude\settings.json"

foreach ($requiredFile in @($codexTomlSrc, $codexAgSettingsSrc, $claudeAgSettingsSrc, $claudeProjectSettingsSrc)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Missing file: $requiredFile"
    }
}

$didTouchAgSettings = $false

function Apply-Codex {
    Write-Log ""
    Write-Log "Applying Codex settings..."
    Backup-File -Path $codexTomlDst
    Copy-File -Source $codexTomlSrc -Destination $codexTomlDst
    Merge-JsonIntoFile -BaseFile $agSettingsDst -OverlayFile $codexAgSettingsSrc
    $script:didTouchAgSettings = $true
}

function Apply-Claude {
    Write-Log ""
    Write-Log "Applying Claude settings..."
    Merge-JsonIntoFile -BaseFile $agSettingsDst -OverlayFile $claudeAgSettingsSrc
    $script:didTouchAgSettings = $true
    Backup-File -Path $claudeGlobalSettingsDst
    Copy-File -Source $claudeProjectSettingsSrc -Destination $claudeGlobalSettingsDst
    Backup-File -Path $claudeProjectSettingsDst
    Copy-File -Source $claudeProjectSettingsSrc -Destination $claudeProjectSettingsDst
}

switch ($Mode) {
    "codex" { Apply-Codex; break }
    "claude" { Apply-Claude; break }
    default { Apply-Codex; Apply-Claude; break }
}

if ($didTouchAgSettings) {
    Reset-AgentPreferenceMigrationFlags -StorageFile $agStorageDst
}

Patch-AntigravityAutoAcceptExtension
Apply-AntigravityAlwaysAllowState

Write-Log ""
if ($DryRun) {
    Write-Log "Dry run complete. No files were changed."
} else {
    Write-Log "Done. Fully restart Antigravity/VS Code and start a new conversation."
}
