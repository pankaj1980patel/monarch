import Foundation

/// Contents of ~/Library/Application Support/Monarch/config.json.
/// Unknown or missing keys fall back to defaults, so old files keep working.
public struct AppConfiguration: Codable, Sendable, Equatable {
    public var version: Int = 1
    /// Master switch for all window shortcuts.
    public var snappingEnabled: Bool = true
    /// Action raw value -> shortcut string ("ctrl+alt+left"). Empty string disables an action.
    public var bindings: [String: String] = Self.defaultBindings
    /// Seconds an Accessibility call may wait for an app before giving up.
    public var axTimeout: Double = 0.25
    /// Moving the mouse to another screen focuses the window last used there (⌃⌥ M).
    public var crossScreenFocus: Bool = true
    /// Hovering moves focus between windows of the focused app on one screen (⌃⌥ H).
    public var sameAppHover: Bool = false
    /// Trackpad gestures. Nil until first set (then imported from Hammerspoon's tuning).
    public var gestures: GestureConfig?

    public init() {}

    public static var defaultBindings: [String: String] {
        Dictionary(uniqueKeysWithValues: Action.allCases.map { ($0.rawValue, $0.defaultShortcut) })
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        snappingEnabled = try c.decodeIfPresent(Bool.self, forKey: .snappingEnabled) ?? true
        axTimeout = try c.decodeIfPresent(Double.self, forKey: .axTimeout) ?? 0.25
        crossScreenFocus = try c.decodeIfPresent(Bool.self, forKey: .crossScreenFocus) ?? true
        sameAppHover = try c.decodeIfPresent(Bool.self, forKey: .sameAppHover) ?? false
        gestures = try c.decodeIfPresent(GestureConfig.self, forKey: .gestures)
        // Start from defaults so a file that lists only some actions keeps the rest.
        var b = Self.defaultBindings
        for (k, v) in try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:] { b[k] = v }
        bindings = b
    }

    /// Resolved bindings plus any entries that failed to parse.
    public func resolvedBindings() -> (bindings: [(Action, Shortcut)], errors: [String]) {
        var out: [(Action, Shortcut)] = []
        var errors: [String] = []
        for action in Action.allCases {
            let text = bindings[action.rawValue] ?? action.defaultShortcut
            if text.isEmpty { continue }
            if let s = Shortcut(text) { out.append((action, s)) } else { errors.append("\(action.rawValue): \"\(text)\"") }
        }
        let known = Set(Action.allCases.map(\.rawValue))
        for k in bindings.keys.sorted() where !known.contains(k) { errors.append("unknown action \"\(k)\"") }
        return (out, errors)
    }

    /// Everything wrong with this configuration, for checking an edited file before it's
    /// applied. Empty when it's safe to use.
    public func validate() -> [String] {
        let (resolved, errors) = resolvedBindings()
        var problems = errors
        // One key combination bound to two actions: only one of them could ever fire.
        var byKey: [Shortcut: [String]] = [:]
        for (a, s) in resolved { byKey[s, default: []].append(a.rawValue) }
        for (s, actions) in byKey where actions.count > 1 {
            problems.append("\(s.description.trimmingCharacters(in: .whitespaces)) is bound to \(actions.sorted().joined(separator: " and "))")
        }
        if !(0.05...5).contains(axTimeout) { problems.append("axTimeout \(axTimeout) is outside 0.05…5 seconds") }
        if let g = gestures {
            func check(_ name: String, _ v: Double, _ r: ClosedRange<Double>) {
                if !r.contains(v) { problems.append("gestures.\(name) \(v) is outside \(r.lowerBound)…\(r.upperBound)") }
            }
            check("threeFinger", g.threeFinger, 0.005...0.5)
            check("fourFinger", g.fourFinger, 0.005...0.5)
            check("ratio", g.ratio, 1...5)
            check("clickGuard", g.clickGuard, 0...2)
            check("lockDistance", g.lockDistance, 0.001...0.2)
            check("overviewTravel", g.overviewTravel, 0.02...1)
            check("thumbAreaWidth", g.thumbAreaWidth, 0.1...0.5)
            check("thumbCorner", g.thumbCorner, 0...0.3)
        }
        return problems.sorted()
    }

    /// This configuration with every value `validate` finds out of range put back to its
    /// default. At launch there are no previous settings to keep (as ⌃⌥⇧ R does), and an
    /// out-of-range value must not be applied silently.
    public func withDefaultsForOutOfRange() -> AppConfiguration {
        var c = self
        if !(0.05...5).contains(c.axTimeout) { c.axTimeout = AppConfiguration().axTimeout }
        if var g = c.gestures {
            let d = GestureConfig()
            if !(0.005...0.5).contains(g.threeFinger) { g.threeFinger = d.threeFinger }
            if !(0.005...0.5).contains(g.fourFinger) { g.fourFinger = d.fourFinger }
            if !(1...5).contains(g.ratio) { g.ratio = d.ratio }
            if !(0...2).contains(g.clickGuard) { g.clickGuard = d.clickGuard }
            if !(0.001...0.2).contains(g.lockDistance) { g.lockDistance = d.lockDistance }
            if !(0.02...1).contains(g.overviewTravel) { g.overviewTravel = d.overviewTravel }
            if !(0.1...0.5).contains(g.thumbAreaWidth) { g.thumbAreaWidth = d.thumbAreaWidth }
            if !(0...0.3).contains(g.thumbCorner) { g.thumbCorner = d.thumbCorner }
            c.gestures = g
        }
        return c
    }
}

/// What reading config.json found, and what may be done about it. A file that exists but
/// can't be read or parsed must never be replaced with defaults: it's the user's hand edit
/// (one trailing comma used to cost them the whole file at the next launch).
public enum ConfigFile {
    public enum Outcome {
        /// No file: first run. Defaults are used and written.
        case missing
        case loaded(AppConfiguration)
        /// The file exists but couldn't be read (permissions, I/O): defaults in memory only.
        case unreadable(String)
        /// The file was read but isn't valid JSON for a config: defaults in memory only.
        case invalid(String)
    }

    public static func interpret(exists: Bool, data: Data?) -> Outcome {
        guard exists else { return .missing }
        guard let data else { return .unreadable("config.json couldn't be read") }
        do { return .loaded(try JSONDecoder().decode(AppConfiguration.self, from: data)) }
        catch { return .invalid("config.json has an error, not applied (fix it and press ⌃⌥⇧ R): \(error.localizedDescription)") }
    }

    /// The configuration to run with and the error to show, if any.
    public static func resolve(_ o: Outcome) -> (AppConfiguration, error: String?) {
        switch o {
        case .missing: return (AppConfiguration(), nil)
        case let .loaded(c): return (c, nil)
        case let .unreadable(e), let .invalid(e): return (AppConfiguration(), e)
        }
    }

    /// Whether Monarch may write the file now: on a first run (no file) or to fill in
    /// first-run settings of a file it read successfully. Never over a file it couldn't use.
    public static func mayWrite(after o: Outcome) -> Bool {
        switch o {
        case .missing, .loaded: return true
        case .unreadable, .invalid: return false
        }
    }

    /// config.json with only `changes` (top-level keys) set, everything else as it is on disk:
    /// for the menu and ⌃⌥ M / ⌃⌥ H toggles. Writing Monarch's whole copy instead replaced edits
    /// not yet reloaded, and a file Monarch couldn't read. Nil when the file isn't a JSON object
    /// (unreadable or broken): then nothing may be written. No file: a full default config.
    public static func patch(_ data: Data?, exists: Bool, changes: [String: Bool]) -> Data? {
        var object: [String: Any]
        if !exists {
            guard let d = try? JSONEncoder().encode(AppConfiguration()),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            object = o
        } else {
            guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            object = o
        }
        for (k, v) in changes { object[k] = v }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
