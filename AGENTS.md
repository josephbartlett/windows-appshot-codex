# Agent Instructions

This repository packages the `windows-appshot` Codex plugin.

## Project Shape

- `.codex-plugin/plugin.json` is the release manifest. Keep its `version` field semantic.
- `skills/windows-appshot/SKILL.md` is the Codex skill entrypoint.
- `scripts/New-Appshot.ps1` captures the foreground Windows window into a local appshot bundle.
- `scripts/Start-AppshotHotkey.ps1` starts the optional hotkey listener.

## Safety Rules

- Do not edit Codex session files or private Codex storage.
- Do not commit generated `appshots/` output or logs.
- Keep the default command target as `NewThread` unless there is a deliberate release decision to change it.
- Preserve PowerShell single-quote escaping in generated clipboard commands.
- Preserve bounded UI Automation traversal and password/off-screen filtering.

## Validation

Before release, run:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" .
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .\skills\windows-appshot
powershell -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw .\scripts\New-Appshot.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Start-AppshotHotkey.ps1)); "scripts parsed"'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12" -ValidateOnly
```

Use a harmless temporary window for runtime capture tests, and remove generated `appshots/` output afterward.
