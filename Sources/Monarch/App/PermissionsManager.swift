import AppKit
import ApplicationServices

/// Accessibility permission. macOS posts a distributed notification when any app's
/// Accessibility trust changes, so we wait for that instead of polling.
@MainActor
final class PermissionsManager {
    /// Accessibility became allowed (first grant, or granted again after being turned off).
    var onGranted: (() -> Void)?
    /// Accessibility was turned off while running: every AX observer is dead from here on.
    var onRevoked: (() -> Void)?
    private var changeToken: NSObjectProtocol?
    private var trusted = AXIsProcessTrusted()

    /// Asked on every hotkey, so cached; refreshed whenever macOS reports an Accessibility change.
    var isTrusted: Bool { trusted }

    init() {
        changeToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {     // the database updates just after
                MainActor.assumeIsolated { self.check() }
            }
        }
    }

    /// Shows the system prompt (System Settings → Privacy & Security → Accessibility).
    func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Acts on changes only: granted → start, revoked → stop.
    private func check() {
        let was = trusted
        trusted = AXIsProcessTrusted()
        if trusted && !was { onGranted?() }
        if !trusted && was { onRevoked?() }
    }
}
