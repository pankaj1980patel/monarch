# Changelog

All notable changes to Monarch are listed here. Versions follow [semantic versioning](https://semver.org).

## [Unreleased]

### Added
- A tenth workspace per display, on the 0 key: ⌥ 0 shows it, ⌥⇧ 0 sends the focused window there, and 0 switches to it in the overview. Sending every window there (`workspace.sendAll.10`) has no default key, because ⌃⌥⇧ 0 still brings back all windows.
- ⌃⇧ 1…9, 0 gathers every window of the focused app, from any workspace or display, onto workspace N of the focused window's display.
- ⌃⌥⌘ A: a second key for bringing back all hidden windows.
- A log at `~/Library/Logs/Monarch/monarch.log`, and **Save Diagnostics Report…** and **Open Log Folder** in the menu.
- MIT license, contributing guide, issue templates.
- Guide for people coming from Rectangle, AeroSpace, yabai and Hammerspoon.
- Homebrew cask (`brew install --cask pankaj1980patel/monarch/monarch`).
- `scripts/build-app.sh --release`: universal (Apple silicon + Intel) build packaged as a zip, with optional Developer ID signing and notarization.

## [0.1.0] - 2026-11-25

First release.

### Added
- Window snapping: halves, thirds, two-thirds, quarters, center, maximize, with ½ → ⅓ → ⅔ cycling, and a full-window toggle.
- Arrange: tile the top N windows of the screen under the mouse.
- Auto focus: cross-display focus, optional same-app hover focus, directional focus.
- ⌘Tab window switcher that raises only the picked window; ⌘\` within the current workspace.
- Nine workspaces per display without macOS Spaces, kept across restarts.
- Overview with drag and drop between workspaces and displays.
- Trackpad gestures: four-finger workspace switching, three-finger overview and App Exposé, resting thumb rejection, scroll blocking during swipes.
- Shortcut sheet, gesture status, `config.json` checked before it's applied, Launch at Login with crash restart.

[Unreleased]: https://github.com/pankaj1980patel/monarch/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pankaj1980patel/monarch/releases/tag/v0.1.0
