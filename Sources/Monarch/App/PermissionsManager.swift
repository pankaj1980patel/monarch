import AppKit
import ApplicationServices

/// Accessibility permission. macOS posts a distributed notification when any app's
/// Accessibility trust changes, so we wait for that instead of polling.
@MainActor
final class PermissionsManager {
    var onGranted: (() -> Void)?
    private var token: NSObjectProtocol?
    private var changeToken: NSObjectProtocol?
    private var trusted = AXIsProcessTrusted()

    /// Asked on every hotkey, so cached; refreshed whenever macOS reports an Accessibility change.
    var isTrusted: Bool { trusted }

    init() {
        changeToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {     // the database updates just after
                MainActor.assumeIsolated { self.trusted = AXIsProcessTrusted() }
            }
        }
    }

    /// Shows the system prompt (System Settings → Privacy & Security → Accessibility).
    func prompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        watch()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        watch()
    }

    private func watch() {
        guard token == nil else { return }
        token = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { _ in
            // The trust database updates just after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainActor.assumeIsolated { self.check() }
            }
        }
    }

    private func check() {
        trusted = AXIsProcessTrusted()
        guard trusted else { return }
        if let token { DistributedNotificationCenter.default().removeObserver(token) }
        token = nil
        onGranted?()
    }
}
