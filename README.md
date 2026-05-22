# Windows Appshot Codex

Windows Appshot is a local Codex plugin for capturing foreground Windows app context for Codex CLI.

Once installed, the normal workflow is:

```text
$windows-appshot create a Windows appshot
$windows-appshot capture Edge Gmail tab
```

This is not native Codex Appshots integration. It cannot inject a new appshot into an already-running Windows Codex app or TUI composer. It creates a local appshot bundle and a supported `codex -i` / `codex --image` command.

## Requirements

- Windows
- PowerShell
- Codex CLI

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

## Use From Codex

After installing as a Codex plugin and starting a new Codex session, invoke:

```text
$windows-appshot create a Windows appshot
```

Focus the app window you want captured during the short delay. The plugin creates an `appshots/` bundle and prepares a supported Codex CLI image command for that bundle.

You can also ask for a specific visible window or browser tab:

```text
$windows-appshot capture Edge Gmail tab
$windows-appshot capture Roblox Studio
$windows-appshot capture Slack OpenAI
```

Target queries search visible top-level windows by process, title, and class name. Browser tab names from Edge, Chrome, Firefox, and Brave are also inspected through UI Automation when available.

The plugin asks for confirmation when there are multiple matches, when the best match is a browser tab, or when confidence is low. Browser tab capture may activate the matched tab, so tab matches are never silently activated without explicit trusted automation in the underlying script.

Before taking the screenshot, query mode verifies that the selected window is foreground. Browser tab captures also verify the selected tab through UI Automation when available or through a stronger active-title match.

## What Gets Captured

Each appshot bundle contains:

- `window.png` - screenshot of the selected Windows app window
- `window-text.txt` - conservative UI Automation control names plus non-editable values
- `metadata.json` - source app, title, process, bounds, capture time, file paths, and selection details
- `prompt.md` - Codex handling notes for the captured context

The default handoff prepares and copies a Codex CLI command that starts a new thread with the screenshot attached when you run it. It does not write into private Codex session storage.

## Direct PowerShell Reference

The plugin commands above are the normal user workflow. Under the hood, the plugin runs `scripts/New-Appshot.ps1`. You can run the script directly for debugging, automation, hotkey setup, or validation.

Manual foreground capture:

```powershell
.\scripts\New-Appshot.ps1
```

Direct query capture:

```powershell
.\scripts\New-Appshot.ps1 Edge Gmail
.\scripts\New-Appshot.ps1 "Roblox Studio"
.\scripts\New-Appshot.ps1 -WindowQuery "Slack OpenAI"
```

List matches without capture:

```powershell
.\scripts\New-Appshot.ps1 -ListWindows
.\scripts\New-Appshot.ps1 Edge Gmail -ListWindows
```

For non-interactive tests or trusted automation, first list matches and then select an index:

```powershell
.\scripts\New-Appshot.ps1 "Appshot Test Window" -ListWindows
.\scripts\New-Appshot.ps1 "Appshot Test Window" -TargetIndex 1 -NoClipboard
```

For browser tab targets, `-TargetIndex` still requires explicit trusted automation:

```powershell
.\scripts\New-Appshot.ps1 Edge Gmail -ListWindows
.\scripts\New-Appshot.ps1 Edge Gmail -TargetIndex 1 -NoWindowConfirmation
```

Use `-NoWindowConfirmation` only when the selected target is intentionally trusted.

### Command Targets

`NewThread` is the default because it is the safest target for captured app context.

```powershell
.\scripts\New-Appshot.ps1 -CommandTarget NewThread
.\scripts\New-Appshot.ps1 -CommandTarget Exec
.\scripts\New-Appshot.ps1 -CommandTarget ResumeLastExec
.\scripts\New-Appshot.ps1 -CommandTarget None
```

- `NewThread` prepares a command that starts a new interactive Codex CLI session with the screenshot attached.
- `Exec` prepares a command that starts a new non-interactive Codex run.
- `ResumeLastExec` prepares a command that continues the latest Codex exec session non-interactively. Use it only when you know the latest exec session is the right destination.
- `None` captures only and does not prepare a clipboard command.

### Hotkey Mode

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

Start a hotkey listener that always targets a query:

```powershell
.\scripts\Start-AppshotHotkey.ps1 -WindowQuery "Edge Gmail"
```

## Repository Layout

```text
.codex-plugin/plugin.json          # Codex plugin manifest
skills/windows-appshot/SKILL.md    # Codex skill entrypoint
scripts/New-Appshot.ps1            # Capture helper used by the skill
scripts/Start-AppshotHotkey.ps1    # Optional hotkey listener
```

## Privacy Notes

Screenshots, window titles, browser tab names, and UI Automation text can include sensitive app content. The helper skips off-screen, editable, password, and generic `Pane` text, does not extract aggregate `TextPattern` document text, writes local files only, and does not edit Codex session files directly. Review generated bundles before sharing them outside your machine.

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

Current release: `v0.2.0`

This project uses semantic versioning.

## License

MIT License. See [LICENSE](LICENSE).
