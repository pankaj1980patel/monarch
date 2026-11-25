/// The shortcut sheet (⌃⌥ /): sections of "keys  description" lines in two balanced columns.
public enum HelpSheet {
    public struct Row: Sendable, Equatable {
        public let keys: String; public let text: String
        public init(keys: String, text: String) { self.keys = keys; self.text = text }
    }
    public struct Section: Sendable, Equatable {
        public let title: String; public let rows: [Row]
        public init(title: String, rows: [Row]) { self.title = title; self.rows = rows }
    }

    /// Toggle states shown as [ON] / [OFF].
    public struct States: Sendable { public var cross: Bool; public var hover: Bool
        public init(cross: Bool, hover: Bool) { self.cross = cross; self.hover = hover } }

    /// Builds the sections from the live bindings (a rebound or disabled key shows as it is).
    public static func sections(bindings: [Action: Shortcut], states: States, gestures: Bool) -> [Section] {
        func k(_ a: Action) -> String? { bindings[a]?.description }
        func row(_ a: Action, _ text: String) -> Row? { k(a).map { Row(keys: $0, text: text) } }
        /// "⌥ 1" … "⌥ 9" as one row "⌥ 1…9", when all nine follow the pattern.
        func family(_ first: Action, _ last: Action, _ text: String) -> Row? {
            guard let a = k(first), let b = k(last), a.hasSuffix("1"), b.hasSuffix("9"),
                  a.dropLast() == b.dropLast() else { return nil }
            return Row(keys: a + "…9", text: text)
        }
        let on = { (b: Bool) in b ? "  [ON]" : "  [OFF]" }
        var out: [Section] = []
        func add(_ title: String, _ rows: [Row?]) {
            let r = rows.compactMap { $0 }
            if !r.isEmpty { out.append(Section(title: title, rows: r)) }
        }
        add("Auto focus (mouse)", [
            row(.toggleCrossScreenFocus, "Cross-screen focus on/off" + on(states.cross)),
            row(.toggleSameAppHover, "Same-app hover focus on/off" + on(states.hover))])
        add("Snap", [
            row(.snapLeft, "Left ½ → ⅓ → ⅔ (repeat)"), row(.snapRight, "Right ½ → ⅓ → ⅔ (repeat)"),
            row(.snapTop, "Top half"), row(.snapBottom, "Bottom half"), row(.maximize, "Maximize"),
            row(.center, "Center (70%)"), row(.topLeft, "Top-left ¼"), row(.topRight, "Top-right ¼"),
            row(.bottomLeft, "Bottom-left ¼"), row(.bottomRight, "Bottom-right ¼"),
            row(.leftThird, "Left ⅓"), row(.centerThird, "Center ⅓"), row(.rightThird, "Right ⅓"),
            row(.leftTwoThirds, "Left ⅔"), row(.rightTwoThirds, "Right ⅔"), row(.undo, "Undo last move"),
            k(.arrangeAll).map { Row(keys: String($0.dropLast()) + "1…9", text: "Tile top N windows (0 = all)") }])
        add("Two screens", [
            row(.moveScreenWest, "Window → left screen"), row(.moveScreenEast, "Window → right screen"),
            row(.moveScreenNextMaximize, "Other screen + maximize"), row(.focusOtherScreen, "Jump to other screen"),
            row(.focusWest, "Focus window left"), row(.focusEast, "Focus window right"),
            row(.focusNorth, "Focus window above"), row(.focusSouth, "Focus window below"),
            row(.fillToggle, "Full window (keeps other screen usable)")])
        add("Workspaces (per screen)", [
            family(.workspace1, .workspace9, "Show workspace N on screen under mouse"),
            family(.moveToWorkspace1, .moveToWorkspace9, "Send focused window to workspace N"),
            gestures ? Row(keys: "4 fingers", text: "Swipe ← next / → previous workspace") : nil,
            row(.toggleOverview, "Overview" + (gestures ? " (also 3-finger swipe ↑)" : "")),
            gestures ? Row(keys: "3 fingers", text: "Swipe ↓ App Exposé (again to close)") : nil,
            row(.restoreAllWindows, "Bring back all hidden windows")])
        add("Switch (raises only one window)", [
            row(.switcherNext, "Last / next window (all workspaces)"),
            row(.switcherPrevious, "Previous window (all workspaces)"),
            row(.switcherWorkspaceNext, "Next window (this workspace)"),
            row(.switcherWorkspacePrevious, "Previous window (this workspace)")])
        add("Helpers", [
            row(.showHelp, "This sheet"), row(.reloadConfig, "Reload config.json"),
            row(.gestureStatus, "Gesture status and recent swipes")])
        return out
    }

    /// Sections split into two columns of near-equal height (whole sections only).
    public static func columns(_ sections: [Section]) -> (left: [Section], right: [Section]) {
        guard sections.count > 1 else { return (sections, []) }
        let heights = sections.map { $0.rows.count + 2 }
        let total = heights.reduce(0, +)
        var best = 1, bestH = Int.max, run = 0
        for k in 0..<sections.count - 1 {
            run += heights[k]
            let h = max(run, total - run)
            if h < bestH { best = k + 1; bestH = h }
        }
        return (Array(sections[..<best]), Array(sections[best...]))
    }
}
