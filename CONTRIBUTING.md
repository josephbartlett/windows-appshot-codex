# Contributing

Thanks for helping improve Windows Appshot.

## Development Setup

Clone the repository on Windows and run validation from the repo root:

```powershell
.\scripts\Test-WindowsAppshotPlugin.ps1 -IncludeHotkeyValidation
```

When working inside Codex with the local system validator skills available, you can also run:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" .
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .\skills\windows-appshot
```

Check PowerShell syntax:

```powershell
powershell -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw .\scripts\New-Appshot.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Start-AppshotHotkey.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Install-WindowsAppshotPlugin.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Test-WindowsAppshotPlugin.ps1)); "scripts parsed"'
```

Validate hotkey registration without starting the listener:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12" -ValidateOnly
```

If Windows PowerShell blocks direct `.ps1` execution, inspect the script first, then rerun it with `powershell -NoProfile -ExecutionPolicy Bypass -File <script-path>`.

## Security And Privacy

- Generated `appshots/` bundles can contain screenshots and UI Automation text from private apps.
- Do not commit generated captures, logs, local credentials, or private Codex state.
- Keep `NewThread` as the default command target unless there is a strong reason to change it.
- Do not remove bounded UI Automation traversal, editable text filtering, password filtering, or off-screen filtering without replacing them with equivalent protections.
- Keep the installer idempotent: it may clone, fast-forward pull, update the marketplace entry, and run `codex plugin add`, but it must not delete unrelated user files.

## Versioning

This project uses semantic versioning. For releases, update `.codex-plugin/plugin.json` with the exact release version and create a matching Git tag such as `v0.1.0`.
