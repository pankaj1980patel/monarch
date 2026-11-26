# Contributing to Monarch

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with the **Bug report** template. The most useful things to include:

- Your Monarch version (first line of the menu) and macOS version.
- How many displays you use, and whether you use a trackpad or a mouse.
- The file from **Save Diagnostics Report…** in the Monarch menu (it includes the recent log from `~/Library/Logs/Monarch/monarch.log`).
- Any changes you made to `config.json`.

## Building

You need macOS 15+ and the Swift 6 toolchain. The Command Line Tools are enough (`xcode-select --install`); Xcode isn't needed.

```sh
swift run MonarchChecks        # logic checks, run these before every pull request
scripts/build-app.sh --run     # build, sign, install to ~/Applications and launch
```

The first build creates a local signing certificate so macOS keeps the Accessibility grant across rebuilds. The script prints a one-time command if it needs you to add that keychain to your search list.

## How the code is organized

- `Sources/MonarchCore`: pure logic with no AppKit (geometry, layouts, workspaces, gesture recognition, config). Anything that can be decided without talking to macOS goes here, so it can be checked by `MonarchChecks`.
- `Sources/Monarch`: the menu bar app. `Window/` talks to Accessibility, `Input/` handles hotkeys and the mouse, `Gestures/` the trackpad, and `Features/` has one folder per feature.
- `Tests/MonarchChecks`: a plain executable of checks for MonarchCore (Swift Testing and XCTest need Xcode).
- `docs/blueprint.html`: architecture, performance rules and roadmap. Read the performance rules before changing anything on the mouse, gesture or hotkey paths.

## Rules worth knowing

- **No polling.** Work happens in response to events (hotkeys, Accessibility notifications, the mouse tap).
- **Never block the main thread on an app.** Accessibility calls go through the app's own queue with a timeout.
- **Private APIs are optional.** Load them at runtime, check them, and turn the feature off if they're missing.
- **Never overwrite a user's `config.json` you couldn't read.** New settings need a default and a range check in `validate()`.
- If you add or change a shortcut or setting, update the shortcut sheet (`Help.swift`) and the README.

## Pull requests

Keep each pull request to one change, describe how you checked it in the real app, and make sure `swift run MonarchChecks` passes. By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
