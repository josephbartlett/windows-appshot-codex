# Changelog

## v0.2.1 - 2026-05-22

- Rework user-facing documentation and plugin metadata to lead with `$windows-appshot` plugin commands before direct PowerShell script usage.

## v0.2.0 - 2026-05-22

- Add query-based window and browser tab target selection.
- Add visible-window listing with `-ListWindows`.
- Add confirmation-first behavior for ambiguous matches and browser tab activation.
- Tighten UI Automation text extraction to skip generic `Pane`, editable, password, off-screen, and aggregate `TextPattern` text.
- Add query support to the hotkey listener.

## v0.1.0 - 2026-05-22

Initial public release.

- Add Windows foreground-window screenshot capture.
- Add visible, non-password UI Automation text extraction.
- Add local appshot bundle output with metadata and prompt files.
- Add Codex CLI command generation using supported image input.
- Add optional global hotkey listener.
- Add Codex plugin manifest and `windows-appshot` skill.
