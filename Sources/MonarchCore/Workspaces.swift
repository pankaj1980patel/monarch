import CoreGraphics
import Foundation

/// A window parked on a hidden workspace. Same fields Hammerspoon uses, so its saved state
/// imports directly and its overview can read Monarch's state file unchanged.
public struct ParkedWindow: Codable, Sendable, Equatable {
    public var ws: Int
    /// UUID of the window's home display.
    public var scr: String
    /// Frame relative to the home display's visible frame (restored exactly).
    public var x: Double, y: Double, w: Double, h: Double
    /// Stacking order when parked: 1 = was the top window.
    public var z: Int
    /// Where the window actually ended up when parked (macOS keeps ~30 pt of title bar on
    /// screen). Nil while the park move is still in flight.
    public var px: Double?, py: Double?

    public init(ws: Int, scr: String, x: Double, y: Double, w: Double, h: Double, z: Int,
                px: Double? = nil, py: Double? = nil) {
        self.ws = ws; self.scr = scr; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
        self.px = px; self.py = py
    }

    public var relativeFrame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// All workspace state: the active workspace per display, and every parked window.
public struct WorkspaceState: Codable, Sendable, Equatable {
    public static let count = 9

    /// Display UUID -> active workspace (1–9). Missing means 1.
    public var active: [String: Int] = [:]
    /// Window ID (as a string, like Hammerspoon) -> parked window.
    public var hidden: [String: ParkedWindow] = [:]

    public init() {}

    public func activeWorkspace(_ uuid: String) -> Int { active[uuid] ?? 1 }
    public func parked(_ id: UInt32) -> ParkedWindow? { hidden[String(id)] }
    public func isParked(_ id: UInt32) -> Bool { hidden[String(id)] != nil }

    /// Workspaces that have windows on a display (always includes the active one).
    public func used(on uuid: String) -> Set<Int> {
        var s: Set<Int> = [activeWorkspace(uuid)]
        for e in hidden.values where e.scr == uuid { s.insert(e.ws) }
        return s
    }

    /// Makes room on top of workspace `n` of `uuid` for `count` windows sent there together:
    /// its parked windows move down the stack, so the sent ones (z 1…count) come back on top.
    public mutating func makeRoom(_ count: Int, onTopOf n: Int, on uuid: String) {
        for (k, e) in hidden where e.scr == uuid && e.ws == n { hidden[k]?.z = e.z + count }
    }

    /// Parked windows of workspace `n` on a display, bottom-most first (restore order).
    public func incoming(_ n: Int, on uuid: String) -> [(id: UInt32, entry: ParkedWindow)] {
        hidden.compactMap { k, e in (e.scr == uuid && e.ws == n) ? UInt32(k).map { ($0, e) } : nil }
            .sorted { $0.entry.z > $1.entry.z }
    }

    /// Workspace number of a window and whether it is showing.
    public func workspace(of id: UInt32, displayUUID: String) -> (number: Int, shown: Bool) {
        if let e = parked(id) { return (e.ws, false) }
        return (activeWorkspace(displayUUID), true)
    }

    /// Imports Hammerspoon's "ws.state.v1" dictionary.
    public init(hammerspoon plist: [String: Any]) {
        for (k, v) in plist["active"] as? [String: Any] ?? [:] {
            if let n = (v as? NSNumber)?.intValue { active[k] = n }
        }
        for (k, v) in plist["hidden"] as? [String: Any] ?? [:] {
            guard UInt32(k) != nil, let e = v as? [String: Any],
                  let ws = (e["ws"] as? NSNumber)?.intValue, let scr = e["scr"] as? String else { continue }
            func d(_ key: String) -> Double? { (e[key] as? NSNumber)?.doubleValue }
            hidden[k] = ParkedWindow(ws: ws, scr: scr, x: d("x") ?? 0, y: d("y") ?? 0,
                                     w: d("w") ?? 800, h: d("h") ?? 600, z: (e["z"] as? NSNumber)?.intValue ?? 0,
                                     px: d("px"), py: d("py"))
        }
    }

    /// Menu bar text: occupied workspaces per display, active in brackets, e.g. "[1] 3  │  [2]".
    public func menuTitle(displayOrder uuids: [String]) -> String {
        uuids.map { uuid in
            let act = activeWorkspace(uuid)
            return used(on: uuid).sorted().map { $0 == act ? "[\($0)]" : "\($0)" }.joined(separator: " ")
        }.joined(separator: "  │  ")
    }
}

public enum Parking {
    /// Candidate top-left points to park a window of `size` just off a corner of `screen`
    /// (full frame), in preference order: bottom-right, bottom-left, right edge, left edge.
    public static func spots(for size: CGSize, screen sf: CGRect) -> [CGPoint] {
        [CGPoint(x: sf.maxX - 1, y: sf.maxY - 1),
         CGPoint(x: sf.minX - size.width + 1, y: sf.maxY - 1),
         CGPoint(x: sf.maxX - 1, y: sf.minY + 40),
         CGPoint(x: sf.minX - size.width + 1, y: sf.minY + 40)]
    }

    /// True if `frame` overlaps any display other than `home` by more than 2 pt each way,
    /// i.e. a parked window would peek onto the other screen.
    public static func overlapsOther(_ frame: CGRect, home: UInt32, displays: [Display]) -> Bool {
        displays.contains { d in
            guard d.id != home else { return false }
            let i = frame.intersection(d.frame)
            return !i.isNull && i.width > 2 && i.height > 2
        }
    }

    /// Still where it was parked? (Within 6 pt; anything else means the user or an app moved it.)
    public static func isAtPark(_ frame: CGRect, _ e: ParkedWindow) -> Bool {
        guard let px = e.px, let py = e.py else { return true }      // park still in flight
        return abs(frame.minX - px) < 6 && abs(frame.minY - py) < 6
    }

    /// Fits a relative frame into another display's visible size (overview drags across screens).
    public static func fit(_ rel: CGRect, into size: CGSize) -> CGRect {
        let w = min(rel.width, size.width), h = min(rel.height, size.height)
        return CGRect(x: max(0, min(rel.minX, size.width - w)), y: max(0, min(rel.minY, size.height - h)), width: w, height: h)
    }
}
