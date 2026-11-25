import AppKit
import MonarchCore

/// The workspace indicator near the bottom of a screen: 1–9, active filled blue, used bright,
/// empty dim, a green ring on the target of ⌥⇧ N. The blue highlight glides from the old
/// workspace to the new one (Core Animation, on the GPU). One panel, reused.
@MainActor
final class WorkspaceHUD {
    private static let cell: CGFloat = 34, pad: CGFloat = 12, height: CGFloat = 54

    private var panel: NSPanel?
    private let digits = HUDView()
    private let highlight = CALayer()
    private var hideWork: DispatchWorkItem?

    func flash(on display: Display, state: WorkspaceState, from: Int?, target: Int?) {
        let panel = self.panel ?? make()
        let act = state.activeWorkspace(display.uuid)
        digits.active = act
        digits.used = state.used(on: display.uuid)
        digits.target = target
        digits.message = nil
        digits.needsDisplay = true

        let width = 9 * Self.cell + 2 * Self.pad
        place(panel, width: width, on: display)
        highlight.isHidden = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = cellRect(from ?? act)
        CATransaction.commit()
        panel.showOpaque()
        if let from, from != act {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.24)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1))  // ease-out
            highlight.frame = cellRect(act)
            CATransaction.commit()
        }
        scheduleHide(after: 0.7)
    }

    /// A one-line message in the same pill ("All windows back").
    func toast(_ text: String, on display: Display?) {
        guard let display else { return }
        let panel = self.panel ?? make()
        digits.message = text
        digits.needsDisplay = true
        highlight.isHidden = true
        place(panel, width: 9 * Self.cell + 2 * Self.pad, on: display)
        panel.showOpaque()
        scheduleHide(after: 0.9)
    }

    private func cellRect(_ n: Int) -> CGRect {
        CGRect(x: Self.pad + CGFloat(n - 1) * Self.cell + 3, y: 10, width: Self.cell - 6, height: Self.height - 20)
    }

    private func place(_ panel: NSPanel, width: CGFloat, on display: Display) {
        // Display rects are in AX coordinates; panels need Cocoa coordinates.
        let screen = SwitcherController.cocoaScreen(for: display.id) ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: (vf.midX - width / 2).rounded(), y: vf.minY + 90, width: width, height: Self.height), display: true)
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if self?.panel?.alphaValue == 0 { self?.panel?.orderOut(nil) } }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: Self.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let container = NSView()
        container.wantsLayer = true
        highlight.backgroundColor = NSColor(red: 0.24, green: 0.52, blue: 1.0, alpha: 0.95).cgColor
        highlight.cornerRadius = 9
        digits.wantsLayer = true
        digits.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 18
            g.tintColor = NSColor(white: 0.04, alpha: 0.6)
            g.contentView = container
            p.contentView = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = 18
            v.layer?.masksToBounds = true
            container.autoresizingMask = [.width, .height]
            v.addSubview(container)
            p.contentView = v
        }
        container.frame = NSRect(x: 0, y: 0, width: 330, height: Self.height)
        container.autoresizingMask = [.width, .height]
        container.layer?.addSublayer(highlight)
        digits.frame = container.bounds
        container.addSubview(digits)
        panel = p
        return p
    }
}

/// Digits 1–9 (or a message) over the sliding highlight.
@MainActor
private final class HUDView: NSView {
    var active = 1
    var used: Set<Int> = []
    var target: Int?
    var message: String?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let cell: CGFloat = 34, pad: CGFloat = 12, h = bounds.height
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        if let message {
            (message as NSString).draw(in: NSRect(x: 0, y: (h - 22) / 2, width: bounds.width, height: 22), withAttributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
            return
        }
        for i in 1...9 {
            let x = pad + CGFloat(i - 1) * cell
            if i == target {
                let ring = NSBezierPath(roundedRect: NSRect(x: x + 3, y: 10, width: cell - 6, height: h - 20), xRadius: 9, yRadius: 9)
                NSColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1).setStroke()
                ring.lineWidth = 2
                ring.stroke()
            }
            let alpha: CGFloat = i == active ? 1 : (used.contains(i) ? 0.9 : 0.3)
            ("\(i)" as NSString).draw(in: NSRect(x: x, y: (h - 22) / 2, width: cell, height: 22), withAttributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .bold),
                .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: para])
        }
    }
}
