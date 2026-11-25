import AppKit
import ApplicationServices
import MonarchCore

/// What the window engine knows about one window. Kept on the main actor.
struct ManagedWindow: Sendable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    var title: String
    var frame: CGRect
    var isMinimized: Bool
}

/// Changes reported by an app's queue to the main-actor cache.
enum WindowEvent: Sendable {
    case discovered(pid_t, [ManagedWindow])
    case upsert(ManagedWindow)
    case removed(pid_t, CGWindowID)
    case focused(pid_t, CGWindowID?)
}

/// One running app: its AX element, its own serial queue and its AXObserver.
///
/// Every AX call for this app runs on `queue`, so a slow or hung app only ever blocks
/// its own queue — never the main thread or another app's actions. Different apps'
/// queues run in parallel, which is what makes multi-window operations fast.
final class TrackedApp: @unchecked Sendable {
    let pid: pid_t
    let name: String
    let element: AXUIElement
    let queue: DispatchQueue

    // Created on the main thread; its run-loop source lives on the main run loop and is
    // removed there in `invalidate()` before this object can be released.
    private var observer: AXObserver?
    private let report: @Sendable (WindowEvent) -> Void

    // Queue-confined state.
    private var windows: [(ref: AXRef, id: CGWindowID)] = []
    private var pendingFrame = Set<CGWindowID>()
    private var appNotificationsAdded = false

    private static let appNotifications = [
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
    ]
    private static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
    ]

    @MainActor
    init(pid: pid_t, name: String, report: @escaping @Sendable (WindowEvent) -> Void) {
        self.pid = pid
        self.name = name
        self.element = AXUIElementCreateApplication(pid)
        self.report = report
        self.queue = DispatchQueue(label: "monarch.app.\(pid)", qos: .userInteractive)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let app = Unmanaged<TrackedApp>.fromOpaque(refcon).takeUnretainedValue()
            app.receive(notification as String, AXRef(element))
        }
        if AXObserverCreate(pid, callback, &obs) == .success, let obs {
            observer = obs
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }

    /// Stops notifications. Must run on the main thread (same run loop the source is on).
    @MainActor
    func invalidate() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    // MARK: Discovery

    /// Subscribes to the app's notifications and reads its current windows. Apps that are
    /// still launching often refuse AX for a moment, so this retries a few times.
    func start(attempt: Int = 0) {
        queue.async { [self] in
            guard let observer else { return }
            if !appNotificationsAdded {
                var ok = true
                for n in Self.appNotifications {
                    let err = AXObserverAddNotification(observer, element, n as CFString, refcon)
                    if err != .success && err != .notificationAlreadyRegistered { ok = false }
                }
                appNotificationsAdded = ok
                if !ok && attempt < 4 {
                    let delay = 0.25 * pow(2, Double(attempt))
                    queue.asyncAfter(deadline: .now() + delay) { self.start(attempt: attempt + 1) }
                    return
                }
            }
            var found: [ManagedWindow] = []
            for el in AX.elements(element, kAXWindowsAttribute) {
                if let w = track(el) { found.append(w) }
            }
            report(.discovered(pid, found))
            report(.focused(pid, AX.element(element, kAXFocusedWindowAttribute).flatMap(AX.windowID)))
        }
    }

    /// Starts tracking one window element; returns nil for non-standard windows. Queue only.
    private func track(_ el: AXUIElement) -> ManagedWindow? {
        guard AX.isStandardWindow(el), let id = AX.windowID(el) else { return nil }
        if !windows.contains(where: { $0.id == id }) {
            windows.append((AXRef(el), id))
            if let observer {
                for n in Self.windowNotifications {
                    AXObserverAddNotification(observer, el, n as CFString, refcon)
                }
            }
        }
        return snapshot(el, id)
    }

    private func snapshot(_ el: AXUIElement, _ id: CGWindowID) -> ManagedWindow? {
        guard let frame = AX.frame(el) else { return nil }
        return ManagedWindow(id: id, pid: pid, title: AX.string(el, kAXTitleAttribute) ?? "",
                             frame: frame, isMinimized: AX.bool(el, kAXMinimizedAttribute) ?? false)
    }

    /// The AX element of a tracked window. Queue only.
    func element(for id: CGWindowID) -> AXUIElement? {
        windows.first(where: { $0.id == id })?.ref.element
    }

    private func knownID(_ el: AXUIElement) -> CGWindowID? {
        windows.first(where: { CFEqual($0.ref.element, el) })?.id
    }

    // MARK: Notifications

    /// Called on the main run loop by the observer. Does no AX work here: hands off to the queue.
    private func receive(_ notification: String, _ ref: AXRef) {
        queue.async { [self] in handle(notification, ref.element) }
    }

    private func handle(_ n: String, _ el: AXUIElement) {
        switch n {
        case kAXWindowCreatedNotification:
            if let w = track(el) { report(.upsert(w)) }

        case kAXUIElementDestroyedNotification:
            // The element is already dead, so match it against what we stored.
            if let i = windows.firstIndex(where: { CFEqual($0.ref.element, el) }) {
                let id = windows.remove(at: i).id
                report(.removed(pid, id))
            }

        case kAXFocusedWindowChangedNotification:
            let id = knownID(el) ?? (track(el)?.id)
            report(.focused(pid, id))

        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            // Dragging fires these dozens of times a second: read the frame at most every 50 ms.
            guard let id = knownID(el), pendingFrame.insert(id).inserted else { return }
            let ref = AXRef(el)
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                pendingFrame.remove(id)
                if let w = snapshot(ref.element, id) { report(.upsert(w)) }
            }

        default:   // minimized, deminimized, title changed
            if let id = knownID(el), let w = snapshot(el, id) { report(.upsert(w)) }
        }
    }
}
