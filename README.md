# Antigravity / Codex Always Allow

Minimal repair scripts for current Antigravity and Codex command approval prompts on Windows.

This replaces the older CDP launcher, extension patching, and VS Code state database approach. Current Antigravity builds store the useful prompt controls under the user's `.gemini` config tree, while Codex still reads `.codex/config.toml`.

## Scripts

Use the smaller script when you only need Codex fixed:

```text
fix_codex_prompts.ps1
```

Use the broader script when Antigravity itself is still prompting:

```text
fix_antigravity_no_prompts.ps1
```

## What It Changes

`fix_codex_prompts.ps1` updates:

```text
%USERPROFILE%\.codex\config.toml
```

`fix_antigravity_no_prompts.ps1` updates:

```text
%USERPROFILE%\.codex\config.toml
%USERPROFILE%\.gemini\config\config.json
%USERPROFILE%\.gemini\config\projects\outside-of-project.json
%USERPROFILE%\.gemini\config\projects\*.json (all active project workspace GUID configs)
```

It adds:

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

and broad Antigravity permission grants:

```json
"unsandboxed(*)"
"command(*)"
"read_file(*)"
"write_file(*)"
"read_url(*)"
"mcp(*)"
```

It also sets the global Antigravity user settings (`config.json`) and project policies (`outside-of-project.json` and all active project workspace GUIDs) to:
- `autoExecutionPolicy`: `"CASCADE_COMMANDS_AUTO_EXECUTION_EAGER"` (auto-executes commands without preview confirmation)
- `permissionPreset`: `"AGENT_PERMISSION_PRESET_TURBO"`
- `fileAccessPolicy`: `"AGENT_SETTING_POLICY_ALLOW"` (allows non-workspace / scratch files without prompts)
- `internetPolicy` / `internetAccessPolicy`: `"AGENT_SETTING_POLICY_ALLOW"`
- `artifactReviewMode`: `"ARTIFACT_REVIEW_MODE_TURBO"`
- Preserves `projectResources.resources` as an array to prevent language server schema deserialization failures.

## Run Codex Only

From this repo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_codex_prompts.ps1
```

Verify without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_codex_prompts.ps1 -VerifyOnly
```

Target a different user profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_codex_prompts.ps1 -UserHome C:\Users\somebody
```

## Run Antigravity + Codex

From this repo:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_antigravity_no_prompts.ps1
```

Verify without changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_antigravity_no_prompts.ps1 -VerifyOnly
```

Target a different user profile:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\fix_antigravity_no_prompts.ps1 -UserHome C:\Users\somebody
```

> **Tip**: If you open a brand-new workspace folder in Antigravity for the first time, run `fix_antigravity_no_prompts.ps1` once so the new project GUID config gets the auto-execution and file access policies applied.

## Backups

Before editing, the script creates timestamped backups next to each changed file:

```text
*.bak-no-prompts-YYYYMMDD-HHMMSS
```

## After Running Codex

Fully close and reopen Codex so the active session reloads the config.

## After Running Antigravity

Fully close and reopen Antigravity so its language server reloads the `.gemini` config.

## Backup / Restore (OS Reload)

Two companion scripts snapshot the permission config so an OS reload doesn't lose it. Each has `-Mode Export` and `-Mode Import` (plus `-WhatIfOnly` for a dry run) and writes a `settings\` folder and `manifest.json` next to itself, so run them from wherever you want the backup stored (e.g. a OneDrive folder):

```text
CodexSettings-Backup.ps1       # ~\.codex (config.toml, rules, automations, user skills)
                               # + ~\.gemini (Antigravity global grants + project policies)
AntigravitySettings-Backup.ps1 # ~\.gemini only, fuller: adds onboarding state and a
                               # -RemapUser switch for username changes
ClaudeSettings-Backup.ps1      # Claude Code: ~\.claude\settings.json, ~\.claude.json,
                               # and all project-level .claude\settings*.json
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexSettings-Backup.ps1 -Mode Export
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexSettings-Backup.ps1 -Mode Import
```

Credentials (`auth.json`, `.credentials.json`) are never exported — sign in again after the reload. Do not commit the generated `settings\` snapshots or `manifest.json` to a public repo; they contain your local paths and permission entries.

Antigravity workspace GUIDs regenerate on a fresh install, so after restoring, run `fix_antigravity_no_prompts.ps1` once per newly opened workspace.

## Claude Code Auto-Continue

`install_claude_auto_continue.ps1` installs a Stop hook (`claude\auto_continue.py`) so Claude Code carries on with routine next steps instead of ending its turn and leaving a suggestion to accept. It still stops when its last message mentions a human gate (approval, spending, credentials, deletes, broker or order capability, ledger writes, a decision that is yours), says it is waiting on a background task, or after 8 automatic continues in a row. Follow-through of work you already asked for, such as pushing a requested change, is treated as a default yes.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_auto_continue.ps1 -Scope User
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_auto_continue.ps1 -Scope Project -ProjectDir C:\src\myrepo
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_auto_continue.ps1 -Scope User -VerifyOnly
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_auto_continue.ps1 -Scope User -Uninstall
```

Settings are merged, backed up first (`*.bak-auto-continue-*`) and written as UTF-8 without a BOM. Requires `python` on PATH. Start a new Claude Code session afterwards; hooks load at session start. `ClaudeSettings-Backup.ps1` now also exports `.claude\hooks` so a restored settings file does not point at a missing script.

## Security Note

This intentionally disables approval prompts and broadens command/file permissions. Use it only on trusted machines and trusted repos.
