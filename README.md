# Google Antigravity Always Allow

Portable config bundles for running Antigravity/Codex/Claude with minimal approval prompts.

On Windows, `install.ps1` also patches the installed `pesosz.antigravity-auto-accept` extension when it is present so Claude/Opus file diffs can auto-accept again.

It also runs `Set-AntigravityAlwaysAllow.ps1`, which updates both Windows Antigravity profiles:

- `%APPDATA%\Antigravity\User`
- `%APPDATA%\Antigravity IDE\User`

That state step persists Auto Accept ON, Background Mode ON, CDP port `9000`, native terminal/review policy sentinels, workspace trust prompts off, and a OneDrive Desktop launcher that starts Antigravity with `--remote-debugging-port=9000`.

## Auto Installer

Use the installer for your shell to apply configs with backup + merge behavior.

### Bash (`install.sh`)

```bash
# Codex + Claude (default), writes .claude/settings.json in current directory
./install.sh --all

# Codex only
./install.sh --codex

# Claude only, target a specific project
./install.sh --claude --project ~/code/my-project
```

### PowerShell on Windows (`install.ps1`)

```powershell
# Codex + Claude (default), writes .claude/settings.json in current directory
.\install.ps1 -All

# Codex only
.\install.ps1 -Codex

# Claude only, target a specific project
.\install.ps1 -Claude -Project C:\code\my-project
```

Use `--dry-run` to preview changes and `--replace` to replace Antigravity settings instead of merge.
Use `-DryRun` and `-Replace` with `install.ps1`.

To apply only the Windows Antigravity state/launcher portion:

```powershell
.\Set-AntigravityAlwaysAllow.ps1

# custom CDP port
.\Set-AntigravityAlwaysAllow.ps1 -Port 9222
```

Installer note: after applying Antigravity settings, the installer resets one-time agent preference migration flags in Antigravity `globalStorage/storage.json` so current Antigravity builds re-import no-prompt preferences on next app restart.
Installer note: the PowerShell installer now also patches `extension.js`, `dist/extension.js`, and `main_scripts/auto-accept.js` inside the installed `pesosz.antigravity-auto-accept` extension, with backups, if that extension exists.
Installer note: the PowerShell installer now also patches Antigravity `state.vscdb` files with backups when Python is available, because Auto Accept ON/OFF and Background Mode are stored in VS Code-style global state rather than `settings.json`.

## Included Bundles

- `codex-no-prompts/`
  - Codex config (`~/.codex/config.toml`) with:
    - `approval_policy = "never"`
    - `sandbox_mode = "danger-full-access"`
  - Antigravity permission settings for no-prompt behavior

- `claude-opus-4.6-no-prompts/`
  - Antigravity Claude settings for:
    - `claude-opus-4.6-thinking`
    - bypass permissions mode and auto-exec flow
  - Claude native settings template for `.claude/settings.json`

## Quick Start

1. Pick the bundle you want.
2. Follow that bundle's `README.md`.
3. Reload Antigravity/VS Code and start a new conversation.

On Windows, fully close Antigravity and reopen it from:

```text
%USERPROFILE%\OneDrive\Desktop\Start Antigravity (CDP 9000).lnk
```

The CDP launcher is required for reliable browser/background approval handling.

## Port Conflict Detection

The `Start Antigravity (CDP 9000).cmd` launcher now auto-detects port conflicts. If port 9000 is occupied (e.g., by MECM/SCCM), it automatically tries 9222, 9333, and 9444 in order.

See [TROUBLESHOOTING-PORTS.md](TROUBLESHOOTING-PORTS.md) for diagnosis commands and known conflicts (including MECM console).

## Security Warning

These settings reduce or disable approval prompts and sandboxing. Use only on trusted machines and trusted repositories.
