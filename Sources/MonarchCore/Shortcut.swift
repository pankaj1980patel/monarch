import Foundation

/// A parsed shortcut such as "ctrl+alt+left": a virtual key code plus Carbon modifier flags.
public struct Shortcut: Sendable, Equatable, Hashable, CustomStringConvertible {
    // Carbon modifier masks (Events.h), duplicated here so this module needs no Carbon import.
    public static let cmd: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public let keyCode: UInt32
    public let modifiers: UInt32
    public let keyName: String

    public init?(_ text: String) {
        var mods: UInt32 = 0
        var key: String?
        for raw in text.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control", "⌃": mods |= Self.control
            case "alt", "opt", "option", "⌥": mods |= Self.option
            case "cmd", "command", "⌘": mods |= Self.cmd
            case "shift", "⇧": mods |= Self.shift
            default:
                guard key == nil else { return nil }   // two non-modifier keys
                key = part
            }
        }
        guard let key, let code = Self.keyCodes[key] else { return nil }
        keyCode = code
        modifiers = mods
        keyName = key
    }

    /// Display form, e.g. "⌃⌥⌘ ←".
    public var description: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.cmd != 0 { s += "⌘" }
        let symbols = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩",
                       "delete": "⌫", "space": "Space", "tab": "⇥", "escape": "⎋"]
        return s + " " + (symbols[keyName] ?? keyName.uppercased())
    }

    /// macOS virtual key codes (kVK_* in HIToolbox/Events.h), US layout.
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
