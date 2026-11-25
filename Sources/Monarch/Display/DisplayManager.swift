import AppKit
import MonarchCore

/// Caches display geometry in Accessibility coordinates. Rebuilt only when macOS reports
/// a screen change (plug/unplug, resolution, arrangement, Dock or menu-bar changes).
@MainActor
final class DisplayManager {
    private(set) var displays: [Display] = []
    var onChange: (() -> Void)?
    private var token: NSObjectProtocol?

    init() {
        refresh()
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { self.refresh(); self.onChange?() } }
    }

    func refresh() {
        let screens = NSScreen.screens
        // screens[0] is the primary display: Cocoa origin (0,0), the reference for AX coordinates.
        guard let primaryHeight = screens.first?.frame.height else { displays = []; return }
        displays = screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
                CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
            } ?? ""
            return Display(id: id, name: s.localizedName, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                           frame: Geometry.cocoaToAX(s.frame, primaryHeight: primaryHeight),
                           visibleFrame: Geometry.cocoaToAX(s.visibleFrame, primaryHeight: primaryHeight),
                           uuid: uuid)
        }
    }
}
