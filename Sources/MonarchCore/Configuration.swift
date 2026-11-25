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
        }
        return problems.sorted()
    }
}
