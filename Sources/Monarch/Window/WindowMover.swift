import ApplicationServices
import MonarchCore

/// Moves and resizes windows as fast as macOS allows. Call on the window's app queue.
enum WindowMover {
    private static let enhancedUI = "AXEnhancedUserInterface"

    /// Sets `win` to `target`. Returns false when it was already there (nothing sent).
    ///
    /// - Skips the move entirely when the frame already matches.
    /// - Turns off the app's "enhanced user interface" mode for the duration: while it's on,
    ///   Chrome, Electron and other apps animate or throttle AX moves (Rectangle does the same).
    /// - Sends size, position, size: the first resize keeps the window from being clamped by
    ///   the old screen, the second fixes apps that adjust size after moving across screens.
    @discardableResult
    static func apply(_ target: CGRect, to win: AXUIElement, app: AXUIElement, current: CGRect) -> Bool {
        if Geometry.nearlyEqual(current, target) { return false }

        let enhanced = AX.bool(app, enhancedUI) == true
        if enhanced { AX.setBool(app, enhancedUI, false) }
        defer { if enhanced { AX.setBool(app, enhancedUI, true) } }

        let resize = !Geometry.sameSize(current, target)
        if resize { AX.setSize(win, target.size) }
        if abs(current.minX - target.minX) > 0.5 || abs(current.minY - target.minY) > 0.5 || resize {
            AX.setPoint(win, target.origin)
        }
        if resize { AX.setSize(win, target.size) }
        return true
    }
}
