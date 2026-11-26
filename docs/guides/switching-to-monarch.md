# Switching to Monarch from Rectangle, AeroSpace, yabai or Hammerspoon

This guide maps what you already use to Monarch's shortcuts and settings, so you can switch in a few minutes. Every Monarch shortcut can be changed in `~/Library/Application Support/Monarch/config.json` (see [Configuration](../../README.md#configuration)), so you can also keep your old keys.

**Before you start:** quit the old tool, or at least turn off its shortcuts. Two apps can't use the same key combination, and Monarch lists any shortcut that another app took first in its menu.

## From Rectangle or Magnet

Monarch's snapping shortcuts use ⌃⌥, like Rectangle's defaults, and most keys match.

| Rectangle | Rectangle default | Monarch default |
|---|---|---|
| Left / right half | ⌃⌥ ← / → | ⌃⌥ ← / → (press again for ⅓, then ⅔) |
| Top / bottom half | ⌃⌥ ↑ / ↓ | ⌃⌥ ↑ / ↓ |
| Maximize | ⌃⌥ ↩ | ⌃⌥ ↩ |
| Center | ⌃⌥ C | ⌃⌥ C |
| Top-left / top-right quarter | ⌃⌥ U / I | ⌃⌥ U / I |
| Bottom-left / bottom-right quarter | ⌃⌥ J / K | ⌃⌥ J / K |
| First / center / last third | ⌃⌥ D / F / G | ⌃⌥ D / F / G |
| First / last two-thirds | ⌃⌥ E / T | ⌃⌥ E / T |
| Next / previous display | ⌃⌥⌘ → / ← | ⌃⌥⌘ → / ← |
| Almost maximize | ⌃⌥ ⌫ | not built in; ⌃⌘ F fills the screen |

**What you get in addition:** ten workspaces per display, an overview, a window switcher, auto focus and trackpad gestures.

**What's different:** Monarch has no drag-to-edge snapping and no gaps setting yet.

## From AeroSpace

Both use their own workspaces instead of macOS Spaces and hide windows by moving them off screen, so the model will feel familiar.

| AeroSpace (common setup) | Monarch default |
|---|---|
| ⌥ 1…9: switch workspace | ⌥ 1…9, ⌥ 0 for workspace 10 (the display under the mouse) |
| ⌥⇧ 1…9: move window to workspace | ⌥⇧ 1…9, ⌥⇧ 0 |
| Move all windows of an app (via a script) | ⌃⇧ 1…9, 0 |
| ⌥ H/J/K/L: focus left/down/up/right | ⌃⌥⇧ ← / ↓ / ↑ / → |
| Tiling layout | ⌃⌥⌘ 0 tiles every window on the screen, ⌃⌥⌘ 1…9 the top N |
| `aerospace.toml` | `config.json` (checked before it's applied) |

**What's different:**
- Monarch doesn't tile automatically. Windows stay where you put them until you snap or tile them.
- Workspaces belong to a display: each display has its own ten, and ⌥ N switches the one under the mouse.
- Monarch adds an overview of all workspaces, a ⌘Tab window switcher and trackpad gestures.

To use vim-style focus keys, rebind them:

```json
{ "bindings": { "focus.west": "alt+h", "focus.south": "alt+j", "focus.north": "alt+k", "focus.east": "alt+l" } }
```

## From yabai and skhd

| yabai / skhd idea | Monarch |
|---|---|
| Spaces created and managed by yabai | Monarch's own workspaces, no Spaces needed, SIP stays on |
| `yabai -m window --focus west` | ⌃⌥⇧ ← (`focus.west`) |
| `yabai -m window --space 2` | ⌥⇧ 2 (`workspace.move.2`) |
| `yabai -m window --display next` | ⌃⌥⌘ → (`screen.moveEast`) |
| focus follows mouse | `crossScreenFocus` (between displays), `sameAppHover` (within one app) |
| skhd hotkey file | `bindings` in `config.json` |

**What's different:** no automatic BSP tiling and no scripting interface. Monarch doesn't need System Integrity Protection turned off for any feature.

## From Hammerspoon

Monarch was written to replace a Hammerspoon window setup, and its default shortcuts come from that setup.

- On its first run, Monarch imports Hammerspoon's saved workspaces and gesture tuning.
- If Hammerspoon is still running, Monarch owns the workspaces and Hammerspoon's overview and gesture code can act as clients. Once you're happy with Monarch, remove the window parts of your `init.lua`.
- Things Hammerspoon can do that Monarch doesn't: anything scripted in Lua. Keep Hammerspoon for those, with the window shortcuts removed.

## From AltTab or the macOS ⌘Tab

Monarch's ⌘Tab lists **windows**, not apps, most recently used first, across every workspace and display. It raises only the window you pick. ⌘\` does the same for the current workspace only.

To keep the macOS app switcher, turn Monarch's off:

```json
{ "bindings": { "switcher.next": "", "switcher.previous": "" } }
```

## From BetterTouchTool or Swish (gestures)

| Gesture | Monarch |
|---|---|
| Four fingers ← / → | Next / previous workspace |
| Three fingers ↑ | Overview |
| Three fingers ↓ | App Exposé |

Turn off the matching gestures in **System Settings → Trackpad → More Gestures** and in the other app, or both will act. Monarch lists conflicts it detects under **Gestures** in its menu.
