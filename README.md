# Monarch: a lightweight window manager for macOS

[![Latest release](https://img.shields.io/github/v/release/pankaj1980patel/monarch)](https://github.com/pankaj1980patel/monarch/releases/latest) [![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)](#install) [![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE) [![Swift 6](https://img.shields.io/badge/Swift-6-orange)](Package.swift)

**Monarch is a free, open-source, native window manager for macOS.** It lives in the menu bar and gives you keyboard window snapping, ten virtual workspaces per display, a ⌘Tab switcher that switches *windows* (not apps), a Mission Control–style overview, mouse-follows-focus, and three- and four-finger trackpad gestures. It's written in Swift 6 and AppKit, has no dependencies, and doesn't need Screen Recording permission.

If you're looking for an alternative to Rectangle, Magnet, Amethyst, yabai, AeroSpace or a Hammerspoon window setup, and you want workspaces that don't use macOS Spaces, Monarch is built for that.

![Monarch overview: each workspace shown as a card listing its windows, with a "+" card for the next empty workspace](docs/images/overview.png)

*The overview (⌃⌥ Space, or swipe up with three fingers). This image uses sample windows. Regenerate it with `Monarch --render-overview-demo docs/images/overview.png`.*

**Contents:** [Features](#features) · [Install](#install) · [Quick start](#quick-start-your-first-5-minutes) · [Shortcuts](#keyboard-shortcuts) · [Gestures](#trackpad-gestures) · [Configuration](#configuration) · [Troubleshooting](#troubleshooting) · [FAQ](#faq) · [Build from source](#build-from-source) · [Design](#design-and-architecture)

## Features

| Feature | What it does |
|---|---|
| **Window snapping** | Halves, quarters, thirds, two-thirds, center and maximize from the keyboard. Pressing ⌃⌥ ← again steps through ½ → ⅓ → ⅔. |
| **Tiling on demand** | ⌃⌥⌘ 1…9 tiles the top N windows on the screen under the mouse. ⌃⌥⌘ 0 tiles all of them. |
| **Workspaces without Spaces** | Each display has ten workspaces of its own (on keys 1–9 and 0), like i3. Switching is instant: no Spaces animation, and System Settings stays as it is. Windows come back exactly where you left them, even after a restart. |
| **Overview** | A Mission Control–style view of every workspace on every display. Drag windows between workspaces, or do everything from the keyboard. |
| **Window switcher** | ⌘Tab lists every window (most recently used first) and raises only the window you pick. ⌘\` does the same for the current workspace. |
| **Auto focus** | Move the mouse to another display and the window you last used there gets focus. Optional: hovering over a window of the same app focuses it. |
| **Directional focus** | Focus the window to the left, right, above or below. |
| **Multi-monitor** | Send windows between displays, jump to the other display, and fill a screen without macOS full screen, so the other display stays usable. |
| **Trackpad gestures** | Swipe with four fingers to change workspace. Swipe up with three for the overview, down with three for App Exposé. A resting thumb or palm is ignored. |
| **Plain-text config** | One JSON file. Every shortcut can be changed or turned off. The file is checked before it's applied, so a typo never breaks your setup. |

### Built to stay out of the way

- **Event-driven, no polling:** Carbon hotkeys, Accessibility observers and a listen-only mouse tap. Monarch uses no CPU while you aren't doing anything.
- **A frozen app can't freeze Monarch:** each app gets its own Accessibility queue with a 0.25 s timeout.
- **Privacy:** no screenshots, no Screen Recording permission, no network access. Only Accessibility is needed.
- **Fails safe:** private APIs (MultitouchSupport, SkyLight focus, Dock notifications) are loaded at runtime and checked. If one is missing on your macOS version, only that feature turns off.
- **Starts at login and restarts if it crashes,** through a launch agent inside the app bundle.

## Install

### With Homebrew

```sh
brew tap pankaj1980patel/monarch https://github.com/pankaj1980patel/monarch
brew install --cask pankaj1980patel/monarch/monarch
```

Use the full name: Homebrew's own `monarch` cask is a different app (a Spotlight-style launcher).

Then allow Monarch under Accessibility (step 3 below).

### Manual download

**[Download the latest release](https://github.com/pankaj1980patel/monarch/releases/latest)** (current version: [Monarch 0.1.0](https://github.com/pankaj1980patel/monarch/releases/download/v0.1.0/Monarch-0.1.0.zip)).

**Requirements:** macOS 15 Sequoia or later on an Apple silicon Mac. Version 0.1.0 is built for arm64 only (later releases will be universal); on an Intel Mac, [build from source](#build-from-source).

1. Unzip the download and move `Monarch.app` to `/Applications` or `~/Applications`.
2. The app isn't notarized yet, so the first time you open it, right-click it and choose **Open**. You can also run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Monarch.app
   ```
3. When asked, allow Monarch in **System Settings → Privacy & Security → Accessibility**. Monarch can't move or focus windows without it.
4. Optional: in the Monarch menu bar menu, turn on **Launch at Login (restarts after a crash)**.

## Quick start: your first 5 minutes

Once Monarch is running, try these in order:

1. **See every shortcut:** press **⌃⌥ /**. Leave the sheet open while you learn.
2. **Snap a window:** press **⌃⌥ ←**, then press it again to go from ½ to ⅓ to ⅔. **⌃⌥ ↩** maximizes, **⌃⌥ C** centers.
3. **Tile what's open:** **⌃⌥⌘ 2** puts your two most recent windows side by side.
4. **Use workspaces:** press **⌥ 2** to switch the screen under the mouse to an empty workspace 2. Then go back with **⌥ 1**, focus a window and press **⌥⇧ 2** to send it to workspace 2. To move every window of an app at once (all your browser windows, say), focus one and press **⌃⇧ 3**. The menu bar shows which workspace each display is on.
5. **Open the overview:** **⌃⌥ Space**, or swipe up with three fingers. Click a window to go to it, or drag it onto another card to move it.
6. **Switch windows:** hold **⌘** and tap **Tab**. A quick ⌘Tab jumps between your last two windows without showing the panel.

> **Modifier key reference:** ⌃ Control · ⌥ Option · ⌘ Command · ⇧ Shift · ↩ Return

> **Coming from another tool?** The [switching guide](docs/guides/switching-to-monarch.md) maps Rectangle, AeroSpace, yabai, Hammerspoon and AltTab shortcuts to Monarch's.

## Keyboard shortcuts

These are the defaults. Every one can be changed in [the config file](#configuration), and **⌃⌥ /** always shows the shortcuts you're actually using.

### Snapping and layout

| Shortcut | Action |
|---|---|
| ⌃⌥ ← / → | Left / right half, then ⅓, then ⅔ when pressed again |
| ⌃⌥ ↑ / ↓ | Top / bottom half |
| ⌃⌥ ↩ | Maximize |
| ⌃⌥ C | Center (70% of the screen) |
| ⌃⌥ U / I / J / K | Top-left / top-right / bottom-left / bottom-right quarter |
| ⌃⌥ D / F / G | Left / center / right third |
| ⌃⌥ E / T | Left / right two-thirds |
| ⌃⌥⌘ 1…9 | Tile the top N windows on the screen under the mouse |
| ⌃⌥⌘ 0 | Tile all windows on that screen |

### Multiple displays and focus

| Shortcut | Action |
|---|---|
| ⌃⌥⌘ ← / → | Move the window to the display on the left / right |
| ⌃⌥⌘ ↩ | Move the window to the other display and maximize it |
| ⌃⌘ F | Fill the screen without macOS full screen (press again to restore) |
| ⌃⌥ N | Jump to the other display |
| ⌃⌥⇧ ← / → / ↑ / ↓ | Focus the window to the left / right / above / below |
| ⌃⌥ M | Turn cross-display auto focus on or off (on by default) |
| ⌃⌥ H | Turn same-app hover focus on or off (off by default) |

### Workspaces

| Shortcut | Action |
|---|---|
| ⌥ 1…9, 0 | Show workspace N on the display under the mouse (0 is workspace 10) |
| ⌥⇧ 1…9, 0 | Send the focused window to workspace N |
| ⌃⌥⇧ 1…9 | Send every window on the display under the mouse to workspace N (workspace 10 has no default key, since ⌃⌥⇧ 0 is taken; bind `workspace.sendAll.10` to add one) |
| ⌃⇧ 1…9, 0 | Send every window of the focused app, from any workspace or display, to workspace N on the focused window's display |
| ⌃⌥⇧ 0 or ⌃⌥⌘ A | Bring back all hidden windows |
| ⌃⌥ Space | Open or close the overview |

### Window switcher

| Shortcut | Action |
|---|---|
| ⌘ Tab / ⌘⇧ Tab | Next / previous window, across all workspaces and displays |
| ⌘ \` / ⌘⇧ \` | Next / previous window in the current workspace only |

While the switcher is open: Tab, ⇧Tab, ← and → move the selection, ↩ or releasing ⌘ picks, ⎋ cancels, and you can hover and click with the mouse.

### Overview

Click a window to go to it. Click a card to switch to that workspace. Drag a window onto a card, on any display, to move it there. From the keyboard: arrows select, ⇧ ← / → moves the selected window one card, holding Space while pressing arrows carries it, 1–9 and 0 switch, ↩ goes, Esc closes.

### Helpers

| Shortcut | Action |
|---|---|
| ⌃⌥ / | Show the shortcut sheet |
| ⌃⌥⇧ R | Reload `config.json` |
| ⌃⌥⇧ G | Show gesture status and recent swipes |

## Trackpad gestures

| Gesture | Action |
|---|---|
| Four fingers ← / → | Next / previous workspace |
| Three fingers ↑ | Open the overview (it follows your fingers) |
| Three fingers ↓ | App Exposé (swipe again to close) |

**Turn off the matching macOS gestures first.** macOS uses the same swipes for Spaces and Mission Control. If both are on, both will act. Monarch lists any conflicts under **Gestures** in its menu, with a button that opens Trackpad Settings. In **System Settings → Trackpad → More Gestures**, turn off or change *Swipe between full-screen applications*, *Mission Control* and *App Exposé*.

### Resting thumb and palm rejection

A thumb resting on the trackpad is ignored during three- and four-finger swipes, so a resting thumb won't turn a two-finger scroll into a three-finger swipe. Tell Monarch where your thumb rests in the `gestures` section:

```json
"gestures": { "thumbArea": "left", "thumbAreaWidth": 0.33 }
```

- `thumbArea`: `left` (right-handed, the default), `right` (left-handed), `both` or `anywhere`.
- `thumbAreaWidth`: the width of the area at each side, from 0.1 to 0.5 of the trackpad.
- `thumbCorners`: a contact that lands in one of these corners always counts as a thumb or palm, even if it moves with the fingers. The default is both left corners and the bottom-right one (mirrored for `right`, all four for `both` and `anywhere`). Choose your own with `["topLeft", "bottomLeft", "bottomRight"]` (`topRight` is also allowed).
- `thumbCorner`: the size of each corner (default 0.15 of the width and height; 0 turns corners off).
- `"thumbRejection": false` counts every contact as a finger.

While a three- or four-finger swipe is under way, Monarch also stops it from scrolling the window under the mouse. Without this, the last two fingers to lift, or a thumb plus one finger left on the trackpad, would scroll. Set `"blockScroll": false` to turn this off.

## Configuration

All settings are in one file:

```
~/Library/Application Support/Monarch/config.json
```

Open it from the menu bar (**Open Configuration File**). After editing, press **⌃⌥⇧ R** or choose **Reload Configuration**. Monarch checks the file first: if it finds a mistake (a typo, an unknown action, two actions on the same key, a value out of range), it keeps your current settings and lists the problems in the menu. You can also check the file from a terminal:

```sh
/Applications/Monarch.app/Contents/MacOS/Monarch --check-config
```

You only need to include what you're changing. Any key you leave out keeps its default.

### Example: change and turn off shortcuts

```json
{
  "bindings": {
    "snap.maximize": "ctrl+alt+m",
    "focus.toggleCrossScreen": "ctrl+alt+shift+m",
    "switcher.next": ""
  }
}
```

An empty string turns a shortcut off. Above, `""` gives ⌘Tab back to macOS. Shortcuts are written as modifiers and a key joined by `+`. The modifiers are `ctrl`, `alt`, `cmd` and `shift`. The modifiers can also be written `control`, `option`/`opt`, `command` or as symbols. Keys are letters, digits, punctuation (`/` `` ` `` `-` `=` `[` `]` `;` `'` `,` `.` `\`), `left` `right` `up` `down`, `return`, `space`, `tab`, `escape`, `delete`, `home`, `end`, `pageup`, `pagedown` and `f1`…`f12`.

### All settings

| Key | Default | Meaning |
|---|---|---|
| `snappingEnabled` | `true` | Master switch for all window shortcuts |
| `crossScreenFocus` | `true` | Moving the mouse to another display focuses the window last used there |
| `sameAppHover` | `false` | Hovering over a window of the focused app focuses it |
| `axTimeout` | `0.25` | Seconds to wait for an app before giving up (0.05–5) |
| `bindings` | see below | Action → shortcut |
| `gestures.enabled` | `true` | Trackpad gestures on or off |
| `gestures.trigger` | `"swipe"` | Four-finger switch fires during the swipe (`swipe`) or when your fingers lift (`lift`) |
| `gestures.threeFinger` / `fourFinger` | `0.07` / `0.10` | How far a swipe must travel to count, as a fraction of the trackpad |
| `gestures.overviewTravel` | `0.18` | Three-finger travel that fully opens the overview |
| `gestures.ratio` | `1.5` | How much more the main direction must move than the other one |
| `gestures.blockScroll` | `true` | Block scrolling during swipes |

### Action names for `bindings`

`snap.left` `snap.right` `snap.top` `snap.bottom` `snap.maximize` `snap.center` `snap.topLeft` `snap.topRight` `snap.bottomLeft` `snap.bottomRight` `snap.leftThird` `snap.centerThird` `snap.rightThird` `snap.leftTwoThirds` `snap.rightTwoThirds` · `screen.moveWest` `screen.moveEast` `screen.moveNextMaximize` `window.fillToggle` · `focus.toggleCrossScreen` `focus.toggleSameAppHover` `focus.otherScreen` `focus.west` `focus.east` `focus.north` `focus.south` · `arrange.all` `arrange.1`…`arrange.9` · `switcher.next` `switcher.previous` `switcher.workspaceNext` `switcher.workspacePrevious` · `workspace.1`…`workspace.10` `workspace.move.1`…`workspace.move.10` `workspace.sendAll.1`…`workspace.sendAll.10` `workspace.gatherApp.1`…`workspace.gatherApp.10` `workspace.restoreAll` `workspace.restoreAll.alt` · `overview.toggle` · `help.show` `config.reload` `gestures.status`

## How workspaces work

Monarch doesn't use macOS Spaces. A window on a hidden workspace is moved just off a corner of its own display, and its exact position is saved. When you switch back, it returns to the same place. As a result:

- Switching is instant, with no animation, and each display switches on its own.
- Workspaces are saved in `~/Library/Application Support/Monarch/workspaces.json` and survive restarts.
- If you plug in, unplug or rearrange displays, every window is brought back so none get lost.
- **If you quit Monarch, press ⌃⌥⇧ 0 (or ⌃⌥⌘ A) first** to bring back all hidden windows. Otherwise they stay just off-screen until Monarch runs again.

## Troubleshooting

**Shortcuts do nothing.** Check that Monarch is allowed under **Privacy & Security → Accessibility**. The menu shows "Accessibility: allowed" when it is. If you replaced the app with a new copy, remove Monarch from that list and add it again.

**Some shortcuts don't work.** Another app may have taken them first. The menu shows "Shortcuts: N active, M taken by another app" and lists which ones. Rebind them in `config.json`.

**My config changes don't apply.** Look for `Config:` lines in the menu, or run `Monarch --check-config`. A file with a mistake is never applied, and it's never overwritten.

**Gestures fire twice, or macOS switches Spaces too.** Turn off the matching macOS trackpad gestures (see [Trackpad gestures](#trackpad-gestures)). Press ⌃⌥⇧ G to see what Monarch detected.

**A two-finger scroll opens the overview.** A resting thumb is being counted as a finger. Set `thumbArea` to match the hand you use, or make `thumbAreaWidth` larger.

**Windows disappeared.** Press ⌃⌥⇧ 0 or ⌃⌥⌘ A to bring back every hidden window.

**It doesn't start at login.** Run `Monarch --login-status`, then `Monarch --register-login`, and allow it under **System Settings → General → Login Items**.

**Something feels slow.** The **Performance** submenu shows how long each action took. **Copy Report** copies it for a bug report.

## FAQ

**How is Monarch different from Rectangle or Magnet?**
Those snap windows. Monarch snaps windows too, and also adds workspaces, an overview, a window switcher, auto focus and trackpad gestures in one small app.

**How is it different from yabai, Amethyst or AeroSpace?**
Monarch doesn't tile automatically. Windows stay where you put them until you snap or tile them. Like AeroSpace, it has its own workspaces instead of macOS Spaces, and it never asks you to turn off System Integrity Protection.

**Do I need Hammerspoon?**
No. Monarch replaces a Hammerspoon setup and runs on its own. If Hammerspoon is installed, Monarch imports its saved workspaces and gesture settings once, on the first run.

**Does it need Screen Recording permission?**
No. The overview and switcher show window titles and app icons, not screenshots.

**Does it work with one display?**
Yes. Features for multiple displays simply have nothing to do.

**Is it free?**
Yes. It's open source under the MIT License.

## Build from source

Requires macOS 15+ and the Swift 6 toolchain (the Command Line Tools are enough; Xcode isn't needed).

```sh
git clone https://github.com/pankaj1980patel/monarch.git
cd monarch
swift run MonarchChecks        # run the logic checks
scripts/build-app.sh --run     # build, sign, install to ~/Applications and launch
```

The build script signs each build with a local self-signed identity, so you don't have to grant Accessibility again after every rebuild.

To make a release zip, run `scripts/build-app.sh --release`. It builds a universal binary (Apple silicon + Intel) and writes `dist/Monarch-<version>.zip`. With an Apple Developer account, set `MONARCH_DEVELOPER_ID` and `MONARCH_NOTARY_PROFILE` to sign it with your Developer ID and notarize it (see the top of the script).

**Project layout:**
- `Sources/MonarchCore`: pure logic (geometry, layouts, workspaces, gestures, config) with no AppKit, so it can be checked on its own.
- `Sources/Monarch`: the menu bar app (Accessibility, hotkeys, displays, UI), with one folder per feature in `Features/`.
- `Tests/MonarchChecks`: checks for MonarchCore.

## Logs and issue reports

Monarch logs what it does (launch and quit, config, shortcuts that failed to register, workspace switches and windows that couldn't be moved, display changes, gestures) to `~/Library/Logs/Monarch/monarch.log`. The file is kept across restarts and rotates at 1 MB. Window titles are never logged. The same lines go to the system log under `dev.monarch.Monarch`:

```sh
log show --last 1h --predicate 'subsystem == "dev.monarch.Monarch"'
```

To report a problem, choose **Save Diagnostics Report…** in the menu. It writes one text file with the version and commit, macOS, displays, permissions, config problems, gesture and workspace state, timings and the recent log, and shows it in Finder.

## Design and architecture

See [docs/blueprint.html](docs/blueprint.html) for the architecture, performance rules and roadmap.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, how the code is organized and what to include in a bug report. Changes in each version are listed in [CHANGELOG.md](CHANGELOG.md).

## License

Monarch is released under the [MIT License](LICENSE).

---

*Keywords: macOS window manager, window snapping, tiling window manager for Mac, virtual desktops, workspaces, Spaces alternative, Mission Control alternative, window switcher, alt-tab for windows, focus follows mouse, trackpad gestures, multi-monitor, menu bar app, Swift, Rectangle alternative, yabai alternative, AeroSpace alternative.*
