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
    /// The window wasn't moved: it was minimized, or its app hidden (⌘H), when its workspace
    /// was left. It still belongs to that workspace; when it wakes up (unminimized, app
    /// shown) while another workspace shows, its own workspace is shown. Nil in older files.
    public var asleep: Bool?

    public init(ws: Int, scr: String, x: Double, y: Double, w: Double, h: Double, z: Int,
                px: Double? = nil, py: Double? = nil, asleep: Bool? = nil) {
        self.ws = ws; self.scr = scr; self.x = x; self.y = y; self.w = w; self.h = h; self.z = z
        self.px = px; self.py = py; self.asleep = asleep
    }

    public var isAsleep: Bool { asleep == true }

    public var relativeFrame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// All workspace state: the active workspace per display, and every parked window.
public struct WorkspaceState: Codable, Sendable, Equatable {
    /// 1–9, and 10 on the 0 key.
    public static let count = 10

    /// Display UUID -> active workspace (1–10). Missing means 1.
    public var active: [String: Int] = [:]
    /// Window ID (as a string, like Hammerspoon) -> parked window.
    public var hidden: [String: ParkedWindow] = [:]
    /// The boot session the window ids belong to (kern.bootsessionuuid). Window ids start
    /// again at every boot, so entries from an earlier boot could match unrelated new windows.
    /// Nil in files from before (and Hammerspoon's).
    public var boot: String?

    public init() {}

    /// Makes the state this boot's. Entries saved during another boot are dropped (their ids
    /// mean other windows now); returns true if any were. A state with no boot recorded is
    /// kept: it can't be told apart, and the window-exists check still applies.
    @discardableResult
    public mutating func adopt(boot current: String) -> Bool {
        defer { boot = current }
        guard let b = boot, b != current, !hidden.isEmpty else { return false }
        hidden.removeAll()
        active.removeAll()
        return true
    }

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

/// ⌃⇧ N: every window of the focused app onto workspace N of one display (the focused
/// window's), from whatever workspace or display it's on now.
public enum AppGather {
    public enum Location: Sendable {
        /// Showing on a display, at this frame (global).
        case shown(on: Display, frame: CGRect)
        /// Parked on a hidden workspace.
        case parked(ParkedWindow)
    }

    public struct Plan: Sendable {
        /// Windows to park now, with their new entries (showing, and N isn't showing on the target).
        public var park: [(id: UInt32, entry: ParkedWindow)] = []
        /// Parked windows that only change workspace or display (they stay parked).
        public var relabel: [(id: UInt32, entry: ParkedWindow)] = []
        /// Windows to bring onto the target display, to these frames (N is showing there).
        public var restore: [(id: UInt32, frame: CGRect)] = []
        public var isEmpty: Bool { park.isEmpty && relabel.isEmpty && restore.isEmpty }
        /// How many windows end up parked on N (for making room on top of it).
        public var parkedOnN: Int { park.count + relabel.count }
    }

    /// `windows`: the app's windows, top-most first (the focused one is put first). `active`:
    /// the workspace showing on `target`. Sizes are fitted to the target display; the windows
    /// go on top of N's stack in this order.
    public static func plan(windows: [(id: UInt32, location: Location)], focused: UInt32,
                            target: Display, workspace n: Int, active: Int) -> Plan {
        let ordered = windows.filter { $0.id == focused } + windows.filter { $0.id != focused }
        let area = target.visibleFrame
        var p = Plan()
        for (z, w) in ordered.enumerated() {
            let rel: CGRect
            var spot: (Double?, Double?) = (nil, nil)
            switch w.location {
            case let .shown(d, f):
                if n == active && d.uuid == target.uuid { continue }          // already there, showing
                rel = f.offsetBy(dx: -d.visibleFrame.minX, dy: -d.visibleFrame.minY)
            case let .parked(e):
                if e.ws == n && e.scr == target.uuid && n != active { continue } // already there, parked
                rel = e.relativeFrame
                spot = (e.px, e.py)
            }
            let fitted = Parking.fit(rel, into: area.size)
            if n == active {
                p.restore.append((w.id, fitted.offsetBy(dx: area.minX, dy: area.minY)))
            } else {
                let e = ParkedWindow(ws: n, scr: target.uuid, x: fitted.minX, y: fitted.minY,
                                     w: fitted.width, h: fitted.height, z: z + 1, px: spot.0, py: spot.1)
                if case .parked = w.location { p.relabel.append((w.id, e)) } else { p.park.append((w.id, e)) }
            }
        }
        return p
    }
}

/// Minimized windows and windows of hidden apps (gap: they used to belong to no workspace).
public enum Sleepers {
    /// The asleep windows (minimized, or app hidden) on `display` when its workspace is left:
    /// they're recorded on that workspace, without moving them. `displayOf`: which display a
    /// window's frame is on.
    public static func leaving(windows: [(id: UInt32, asleep: Bool, frame: CGRect)], display: UInt32,
                               isParked: (UInt32) -> Bool, displayOf: (CGRect) -> UInt32?) -> [UInt32] {
        windows.filter { $0.asleep && !isParked($0.id) && displayOf($0.frame) == display }.map(\.id).sorted()
    }

    public enum Wake: Equatable, Sendable {
        /// Still asleep: nothing to do.
        case stay
        /// Awake on its own workspace (it's showing): just forget the entry.
        case forget
        /// Awake while another workspace shows: show its workspace (like a Dock click).
        case showWorkspace(Int)
    }

    /// An asleep window's state changed. `awake`: no longer minimized and its app not hidden.
    public static func wake(_ e: ParkedWindow, awake: Bool, active: Int) -> Wake {
        guard awake else { return .stay }
        return e.ws == active ? .forget : .showWorkspace(e.ws)
    }
}

extension WorkspaceState {
    /// Entries parked on displays that aren't connected (unplugged while Monarch wasn't running
    /// or was off): nothing can switch to them, so they're brought back. Removed and returned.
    public mutating func takeOnMissingDisplays(connected: Set<String>) -> [(id: UInt32, entry: ParkedWindow)] {
        var out: [(id: UInt32, entry: ParkedWindow)] = []
        for (k, e) in hidden where !connected.contains(e.scr) { if let id = UInt32(k) { out.append((id, e)) } }
        for o in out { hidden.removeValue(forKey: String(o.id)) }
        return out.sorted { $0.id < $1.id }
    }
}
