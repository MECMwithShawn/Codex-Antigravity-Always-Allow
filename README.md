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
```

It also sets the outside-project Antigravity policy to allow file access, eager command execution, and turbo artifact review.

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

## Backups

Before editing, the script creates timestamped backups next to each changed file:

```text
*.bak-no-prompts-YYYYMMDD-HHMMSS
```

## After Running Codex

Fully close and reopen Codex so the active session reloads the config.

## After Running Antigravity

Fully close and reopen Antigravity so its language server reloads the `.gemini` config.

## Security Note

This intentionally disables approval prompts and broadens command/file permissions. Use it only on trusted machines and trusted repos.
