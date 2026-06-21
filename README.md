# Antigravity Always Allow

Minimal repair script for current Antigravity/Codex command approval prompts on Windows.

This replaces the older CDP launcher, extension patching, and VS Code state database approach. Current Antigravity builds store the useful prompt controls under the user's `.gemini` config tree, while Codex still reads `.codex/config.toml`.

## What It Changes

The script updates these files for the current Windows user:

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

## Run

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

## After Running

Fully close and reopen Antigravity so its language server reloads the config.

## Security Note

This intentionally disables approval prompts and broadens command/file permissions. Use it only on trusted machines and trusted repos.
