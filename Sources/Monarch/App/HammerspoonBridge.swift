import AppKit
import CoreGraphics
import MonarchCore

/// Link to the parts of the Hammerspoon config that still run (fallback only, if Monarch stops).
///
/// Monarch owns workspaces. Hammerspoon's overview and four-finger swipes act as clients:
/// - they send commands ("switch 3 <display-uuid>", "place <id> <uuid> <n>", "reveal <id>",
///   "restoreAll") as the distributed notification `dev.monarch.Monarch.command`;
/// - Monarch saves its state to workspaces.json (Hammerspoon's own format) and posts
///   `dev.monarch.Monarch.workspaces`, so Hammerspoon reloads it and the overview stays right.
@MainActor
final class HammerspoonBridge {
    enum Command {
        case switchTo(Int, displayUUID: String)
        case place(CGWindowID, displayUUID: String, workspace: Int)
        case reveal(CGWindowID)
        case restoreAll
        case overview(open: Bool?)          // nil = toggle
        case gesture(active: Bool)          // three/four fingers down (true) or all lifted (false)
    }

    private static let domain = "org.hammerspoon.Hammerspoon" as CFString
    private static let commandNote = Notification.Name("dev.monarch.Monarch.command")
    private static let stateNote = Notification.Name("dev.monarch.Monarch.workspaces")
    private static let overviewNote = Notification.Name("dev.monarch.Monarch.overview")

    var onCommand: ((Command) -> Void)?
    private var token: NSObjectProtocol?

    init() {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Self.commandNote, object: nil, queue: .main
        ) { note in
            // Commands are a few words: anything longer isn't one of ours.
            let text = (note.object as? String).flatMap { $0.utf8.count <= 128 ? $0 : nil } ?? ""
            MainActor.assumeIsolated {
                // Distributed notifications carry no sender, so any app could post these. They're
                // only meant for Hammerspoon's fallback config: ignore them unless it's running.
                guard Self.hammerspoonRunning, let c = Self.parse(text) else { return }
                self.onCommand?(c)
            }
        }
    }

    static var hammerspoonRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: domain as String).isEmpty
    }

    /// Hammerspoon's saved workspaces, for the one-time import on Monarch's first run.
    static func importHammerspoonState() -> WorkspaceState? {
        CFPreferencesAppSynchronize(domain)
        guard let plist = CFPreferencesCopyAppValue("ws.state.v1" as CFString, domain) as? [String: Any] else { return nil }
        return WorkspaceState(hammerspoon: plist)
    }

    /// Tells Hammerspoon that workspaces.json changed.
    func stateChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.stateNote, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Tells Hammerspoon's gesture code whether the overview is open (a swipe down then closes it).
    func overviewChanged(open: Bool) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.overviewNote, object: open ? "open" : "closed", userInfo: nil, deliverImmediately: true)
    }

    static func parse(_ text: String) -> Command? {
        let p = text.split(separator: " ").map(String.init)
        switch p.first {
        case "switch" where p.count == 3:
            guard let n = Int(p[1]), (1...WorkspaceState.count).contains(n) else { return nil }
            return .switchTo(n, displayUUID: p[2])
        case "place" where p.count == 4:
            guard let id = UInt32(p[1]), let n = Int(p[3]), (1...WorkspaceState.count).contains(n) else { return nil }
            return .place(id, displayUUID: p[2], workspace: n)
        case "reveal" where p.count == 2:
            return UInt32(p[1]).map { .reveal($0) }
        case "restoreAll":
            return .restoreAll
        case "overview" where p.count == 2:
            switch p[1] { case "open": return .overview(open: true); case "close": return .overview(open: false)
                          case "toggle": return .overview(open: nil); default: return nil }
        case "gesture" where p.count == 2:
            return p[1] == "begin" ? .gesture(active: true) : p[1] == "lift" ? .gesture(active: false) : nil
        default:
            return nil
        }
    }
}
