# Agent Instructions

This repository packages the `windows-appshot` Codex plugin.

## Project Shape

- `.codex-plugin/plugin.json` is the release manifest. Keep its `version` field semantic.
- `README.md` is user-facing plugin documentation. Keep `$windows-appshot` commands before direct PowerShell script references unless the section is explicitly for development, validation, or advanced script usage.
- `skills/windows-appshot/SKILL.md` is the Codex skill entrypoint.
- `scripts/New-Appshot.ps1` captures the foreground Windows window into a local appshot bundle.
- `scripts/Start-AppshotHotkey.ps1` starts the optional hotkey listener.

## Safety Rules

- Do not edit Codex session files or private Codex storage.
- Do not commit generated `appshots/` output or logs.
- Do not commit or push without explicit user approval in the current conversation.
- Keep the default command target as `NewThread` unless there is a deliberate release decision to change it.
- Preserve PowerShell single-quote escaping in generated clipboard commands.
- Preserve bounded UI Automation traversal and generic Pane/editable/password/off-screen filtering.
- Do not reintroduce aggregate UI Automation `TextPattern` extraction without a privacy review.
- Do not make query-based capture silently accept ambiguous matches. Browser tab activation must remain confirmation-first unless `-NoWindowConfirmation` is explicitly supplied for tests or trusted automation.
- `-TargetIndex` is allowed as explicit selection for regular windows after listing. If the indexed target is a browser tab, it must still require `-NoWindowConfirmation`.
- Query capture must verify that the selected window is foreground before screenshot capture. Browser-tab capture must also verify UI Automation selected-tab state when available or a strong active-title match for the selected tab.

## Review Gate

After any code, script, skill, or documentation change, and before any commit, push, version bump, tag, or release, run a PASS/BLOCK review with at least five focused reviewers:

1. Packaging/version/repo hygiene
2. Script/runtime correctness
3. Security/privacy
4. Docs/skill/user workflow
5. Release/process readiness

All reviewers must return `PASS` before proceeding. Any `BLOCK` requires fixes and another full review round, repeated as many times as necessary.

## Validation

Before release, run:

```powershell
python "$HOME\.codex\skills\.system\plugin-creator\scripts\validate_plugin.py" .
python "$HOME\.codex\skills\.system\skill-creator\scripts\quick_validate.py" .\skills\windows-appshot
powershell -NoProfile -Command '$null = [scriptblock]::Create((Get-Content -Raw .\scripts\New-Appshot.ps1)); $null = [scriptblock]::Create((Get-Content -Raw .\scripts\Start-AppshotHotkey.ps1)); "scripts parsed"'
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Start-AppshotHotkey.ps1 -Hotkey "Ctrl+Shift+F12" -ValidateOnly
```

Use a harmless temporary window for runtime capture tests, and remove generated `appshots/` output afterward.
