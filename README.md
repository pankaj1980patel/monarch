# Monarch

A lightweight native macOS window manager (Swift 6 / AppKit, menu bar app) that replaces a Hammerspoon setup: snapping, auto focus, a custom ⌘Tab switcher, nine workspaces per display, an overview, and three/four-finger trackpad gestures.

- Event-driven: Carbon hotkeys, AX observers, a listen-only mouse tap; no polling.
- Per-app Accessibility queues with a 0.25 s timeout, so a hung app can't stall the rest.
- No screenshots, no Screen Recording permission.
- Private APIs (MultitouchSupport, SkyLight focus, Dock notifications) are loaded at runtime and checked; if missing, the feature switches off.

## Build

Requires macOS 15+ and the Swift 6 toolchain (Command Line Tools are enough).

```sh
swift run MonarchChecks        # checks
scripts/build-app.sh --run     # build, sign, install to ~/Applications and launch
```

The build script signs with a local self-signed identity so the Accessibility grant survives rebuilds.

## Shortcuts

Press ⌃⌥ / for the full sheet. Settings live in `~/Library/Application Support/Monarch/config.json` and reload on save.

## Design

See [docs/blueprint.html](docs/blueprint.html) for the architecture, performance rules and roadmap.
