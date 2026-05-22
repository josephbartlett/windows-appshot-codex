# Windows Appshot Codex

Windows Appshot is a local Codex plugin for capturing foreground Windows app context for Codex CLI.

It creates a local bundle with:

- `window.png` - foreground-window screenshot
- `window-text.txt` - visible, non-password Windows UI Automation text
- `metadata.json` - source app, title, process, bounds, capture time, and file paths
- `prompt.md` - Codex handling notes for the captured context

This is not native Codex Appshots integration. It cannot inject a new appshot into an already-running Windows Codex app or TUI composer. It creates a local bundle and a supported `codex -i` / `codex --image` command.

## Requirements

- Windows
- PowerShell
- Codex CLI

## Quick Start

Run from this repo:

```powershell
.\scripts\New-Appshot.ps1
```

Focus the app window you want captured during the short delay. The script writes an `appshots/` bundle under the current directory and copies a Codex command to your clipboard.

By default the copied command starts a new interactive Codex CLI session:

```powershell
codex -i '...\window.png' 'Use this Windows appshot bundle...'
```

## Command Targets

`NewThread` is the default because it is the safest target for captured app context.

```powershell
.\scripts\New-Appshot.ps1 -CommandTarget NewThread
.\scripts\New-Appshot.ps1 -CommandTarget Exec
.\scripts\New-Appshot.ps1 -CommandTarget ResumeLastExec
.\scripts\New-Appshot.ps1 -CommandTarget None
```

- `NewThread` starts a new interactive Codex CLI session with the screenshot attached.
- `Exec` starts a new non-interactive Codex run.
- `ResumeLastExec` continues the latest Codex exec session non-interactively. Use it only when you know the latest exec session is the right destination.
- `None` captures only and does not prepare a clipboard command.

## Hotkey Mode

Start the listener:

```powershell
.\scripts\Start-AppshotHotkey.ps1
```

Default hotkey: `Ctrl+Alt+Space`

Press `Ctrl+C` in the listener terminal to stop it.

Choose another hotkey:

```powershell
.\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12"
```

## Codex Plugin Layout

This repository is the plugin root:

```text
.codex-plugin/plugin.json
skills/windows-appshot/SKILL.md
scripts/New-Appshot.ps1
scripts/Start-AppshotHotkey.ps1
```

After installing as a Codex plugin and starting a new Codex session, invoke:

```text
$windows-appshot create a Windows appshot
```

## Install As A Personal Plugin

Clone this repository into your personal plugin folder:

```powershell
git clone https://github.com/josephbartlett/windows-appshot-codex.git "$HOME\plugins\windows-appshot"
```

Add a personal marketplace entry at `$HOME\.agents\plugins\marketplace.json`:

```json
{
  "name": "personal",
  "interface": {
    "displayName": "Personal"
  },
  "plugins": [
    {
      "name": "windows-appshot",
      "source": {
        "source": "local",
        "path": "./plugins/windows-appshot"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

Install it:

```powershell
codex plugin add windows-appshot@personal
```

Restart Codex sessions after installation so the skill is loaded.

## Privacy Notes

Screenshots and UI Automation text can include sensitive app content. The helper skips off-screen and password controls, writes local files only, and does not edit Codex session files directly. Review generated bundles before sharing them outside your machine.

Generated captures are ignored by git through `.gitignore`.

## Validation

Validate the plugin manifest:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" .
```

Validate the skill:

```powershell
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .\skills\windows-appshot
```

Parse-check the scripts:

```powershell
powershell -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw .\scripts\New-Appshot.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Start-AppshotHotkey.ps1)); "scripts parsed"'
```

Validate hotkey registration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12" -ValidateOnly
```

## Version

Current release: `v0.1.0`

This project uses semantic versioning.

## License

MIT License. See [LICENSE](LICENSE).
