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

## Install Or Update

Clone this repository, inspect the installer, then run it from PowerShell:

```powershell
New-Item -ItemType Directory -Force "$HOME\plugins" | Out-Null
git clone https://github.com/josephbartlett/windows-appshot-codex.git "$HOME\plugins\windows-appshot"
Get-Content "$HOME\plugins\windows-appshot\scripts\Install-WindowsAppshotPlugin.ps1"
& "$HOME\plugins\windows-appshot\scripts\Install-WindowsAppshotPlugin.ps1"
```

The installer clones or updates the plugin at `$HOME\plugins\windows-appshot`, creates or updates the personal marketplace entry at `$HOME\.agents\plugins\marketplace.json`, and runs `codex plugin add windows-appshot@personal` when Codex CLI is available.

From an existing clone, run:

```powershell
.\scripts\Install-WindowsAppshotPlugin.ps1
```

Restart Codex sessions after installation so the skill is loaded.

### Manual Install

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

## Troubleshooting

`$windows-appshot` is not available:

- Restart the Codex session after installing the plugin.
- Run `.\scripts\Install-WindowsAppshotPlugin.ps1` again to update the checkout and marketplace entry.
- Confirm the personal marketplace entry points to `./plugins/windows-appshot`.

Installer reports malformed marketplace JSON:

- Back up `$HOME\.agents\plugins\marketplace.json`.
- Repair the JSON manually, or rename the file and rerun the installer to create a fresh personal marketplace.
- The installer writes through a temporary file and keeps `marketplace.json.bak` when replacing an existing marketplace.

Installer reports permission denied or read-only files:

- Run from a terminal that can write to `$HOME\plugins` and `$HOME\.agents\plugins`.
- Avoid mixing elevated and non-elevated terminals for the same install path.
- Use writable alternate paths when needed:

```powershell
.\scripts\Install-WindowsAppshotPlugin.ps1 -PluginsRoot "$env:TEMP\codex-plugins" -MarketplacePath "$env:TEMP\codex-marketplace\marketplace.json"
```

PowerShell reports that running scripts is disabled:

- Inspect the script first, then run it with a process-scoped execution policy bypass:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\plugins\windows-appshot\scripts\Install-WindowsAppshotPlugin.ps1"
```

- If the file is blocked because it came from the internet, use `Unblock-File` only after reviewing the script:

```powershell
Unblock-File "$HOME\plugins\windows-appshot\scripts\Install-WindowsAppshotPlugin.ps1"
```

Installer reports a dirty plugin checkout:

- Commit, stash, or revert local edits in `$HOME\plugins\windows-appshot`, then rerun.
- Use `-AllowDirty` only for a deliberate development checkout.

Installer reports a detached checkout or missing upstream:

- Return the plugin checkout to a normal branch and update it:

```powershell
Set-Location "$HOME\plugins\windows-appshot"
git switch main
git pull --ff-only
```

- If the checkout was manually edited or moved, reclone the plugin instead. Use `-NoPull` only for deliberate local-source testing.

No window or tab matches the query:

- Use a broader query first, then inspect matches with `.\scripts\New-Appshot.ps1 <query> -ListWindows`.
- Browser tab names depend on what the browser exposes through UI Automation.
- Some apps expose little or no UI Automation text; the screenshot remains the visual source of truth.

Browser tab capture asks for confirmation:

- This is intentional. Activating a browser tab can change app state.
- For automation, list matches first and use `-TargetIndex` only with `-NoWindowConfirmation` when the selected tab is intentionally trusted.

Foreground verification fails:

- Bring the target app to the foreground and retry.
- Avoid mixing elevated and non-elevated terminals/apps when possible; Windows focus and UI Automation access can differ across integrity levels.
- If the app opens a modal, menu, or permission prompt during capture, close it and retry with the desired final state visible.

Captured text is missing expected content:

- UI Automation output is partial by design.
- Editable controls, password fields, off-screen controls, generic `Pane` text, and aggregate `TextPattern` document text are intentionally skipped.
- If hidden or scrolled content matters, capture another appshot with that content visible or provide a direct file/export.

## Repository Layout

```text
.codex-plugin/plugin.json          # Codex plugin manifest
skills/windows-appshot/SKILL.md    # Codex skill entrypoint
scripts/New-Appshot.ps1            # Capture helper used by the skill
scripts/Start-AppshotHotkey.ps1    # Optional hotkey listener
scripts/Install-WindowsAppshotPlugin.ps1 # Personal plugin install/update helper
scripts/Test-WindowsAppshotPlugin.ps1    # Repo-local validation entrypoint
```

## Privacy Notes

Screenshots, window titles, browser tab names, and UI Automation text can include sensitive app content. The helper skips off-screen, editable, password, and generic `Pane` text, does not extract aggregate `TextPattern` document text, writes local files only, and does not edit Codex session files directly. Review generated bundles before sharing them outside your machine.

Generated captures are ignored by git through `.gitignore`.

## Validation

Run repo validation:

```powershell
.\scripts\Test-WindowsAppshotPlugin.ps1 -IncludeHotkeyValidation
```

When working inside Codex with the local system validator skills available, you can also run:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" .
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .\skills\windows-appshot
```

The GitHub Actions workflow runs the repo-local validation script on Windows for pushes, pull requests, and manual dispatch.

Parse-check the PowerShell scripts directly:

```powershell
powershell -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw .\scripts\New-Appshot.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Start-AppshotHotkey.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Install-WindowsAppshotPlugin.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Test-WindowsAppshotPlugin.ps1)); "scripts parsed"'
```

Validate hotkey registration:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12" -ValidateOnly
```

## Version

Current release: `v0.3.0`

This project uses semantic versioning.

## License

MIT License. See [LICENSE](LICENSE).
