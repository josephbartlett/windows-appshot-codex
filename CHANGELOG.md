# Changelog

## Unreleased

## v0.3.0 - 2026-05-22

- Add GitHub Actions validation for plugin metadata, skill metadata, docs, and PowerShell syntax.
- Add a one-command install/update script for personal Codex plugin setup.
- Harden installer behavior with dirty-checkout protection, marketplace JSON backup writes, malformed JSON errors, and duplicate entry collapse.
- Expand repo-local validation with installer smoke coverage and capture safety-invariant checks.
- Add troubleshooting guidance for install, query matching, browser-tab confirmation, foreground verification, and partial UI Automation text.

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
