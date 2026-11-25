import AppKit

/// A short glass notice on the screen under the mouse ("Cross-screen focus: ON").
/// One panel, created on first use and reused; it never takes focus.
@MainActor
final class Toast {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?
    /// Bumped by every show, so a fade-out that finishes after a newer toast appeared
    /// doesn't hide the newer one.
    private var generation = 0

    func show(_ text: String, seconds: Double = 0.9) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 44, height: label.frame.height + 24)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.minY + vf.height * 0.18,
                              width: size.width, height: size.height), display: false)
        label.frame.origin = NSPoint(x: 22, y: 12)
        generation += 1
        let gen = generation
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                self.panel?.orderOut(nil)
            } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 14
        glass.layer?.masksToBounds = true
        glass.autoresizingMask = [.width, .height]
        p.contentView = glass

        let l = NSTextField(labelWithString: "")
        l.font = .systemFont(ofSize: 17, weight: .semibold)
        l.textColor = .labelColor
        glass.addSubview(l)
        label = l
        panel = p
        return p
    }
}
