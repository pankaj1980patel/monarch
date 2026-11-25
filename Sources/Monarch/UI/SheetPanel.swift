import AppKit
import MonarchCore

/// A two-column sheet in the middle of the screen under the mouse: the shortcut help (⌃⌥ /)
/// and the gesture status (⌃⌥⇧ G). The text shrinks until it fits, so it works on the
/// MacBook screen as well as the LG. Closes on click, Esc, the same shortcut again, or after
/// 15 seconds. It never activates Monarch (non-activating key panel). Built on first use.
@MainActor
final class SheetPanel {
    private var panel: SheetWindow?
    private var view: SheetView?
    private var closeWork: DispatchWorkItem?
    private(set) var shownKind: String?

    var isShown: Bool { panel?.isVisible == true }

    /// Shows the sheet, or closes it if the same kind is already showing.
    func toggle(kind: String, title: String, left: [HelpSheet.Section], right: [HelpSheet.Section]) {
        if isShown && shownKind == kind { close(); return }
        show(kind: kind, title: title, left: left, right: right)
    }

    func show(kind: String, title: String, left: [HelpSheet.Section], right: [HelpSheet.Section]) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let p = panel ?? make()
        guard let view else { return }

        // Largest font size (15 down to 8) at which the sheet fits 96 % of the screen.
        var size: CGFloat = 15
        var content = SheetView.Layout.make(title: title, left: left, right: right, size: size)
        while (content.size.width > area.width * 0.96 || content.size.height > area.height * 0.96) && size > 8 {
            size -= 0.5
            content = SheetView.Layout.make(title: title, left: left, right: right, size: size)
        }
        view.layout = content
        let s = content.size
        p.setFrame(NSRect(x: area.midX - s.width / 2, y: area.midY - s.height / 2, width: s.width, height: s.height), display: true)
        view.frame = p.contentView?.bounds ?? .zero
        view.needsDisplay = true
        p.alphaValue = 1
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(view)            // Esc closes
        shownKind = kind

        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    func close() {
        closeWork?.cancel()
        panel?.orderOut(nil)
        shownKind = nil
    }

    private func make() -> SheetWindow {
        let p = SheetWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        // Blur behind, so whatever is underneath doesn't bleed through the text.
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        let v = SheetView()
        v.autoresizingMask = [.width, .height]
        v.onClose = { [weak self] in self?.close() }
        blur.addSubview(v)
        p.contentView = blur
        panel = p
        view = v
        return p
    }
}

private final class SheetWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SheetView: NSView {
    struct Layout {
        let title: NSAttributedString
        let columns: [NSAttributedString]
        let columnWidths: [CGFloat]
        let titleHeight: CGFloat
        let size: CGSize
        static let pad: CGFloat = 24, gap: CGFloat = 36

        static func make(title: String, left: [HelpSheet.Section], right: [HelpSheet.Section], size: CGFloat) -> Layout {
            let t = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: size + 2, weight: .bold), .foregroundColor: NSColor.white])
            let cols = [left, right].filter { !$0.isEmpty }.map { column($0, size: size) }
            let rects = cols.map { $0.boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]) }
            let widths = rects.map { ceil($0.width) + 2 }
            let th = ceil(t.boundingRect(with: NSSize(width: 10_000, height: 100), options: [.usesLineFragmentOrigin]).height) + size
            let w = max(widths.reduce(0, +) + gap * CGFloat(max(0, widths.count - 1)),
                        ceil(t.size().width)) + 2 * pad
            let h = (rects.map { ceil($0.height) }.max() ?? 0) + th + 2 * pad
            return Layout(title: t, columns: cols, columnWidths: widths, titleHeight: th, size: CGSize(width: w, height: h))
        }

        private static func column(_ sections: [HelpSheet.Section], size: CGFloat) -> NSAttributedString {
            let keyFont = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            let textFont = NSFont.systemFont(ofSize: size)
            let keyWidth = sections.flatMap(\.rows).map {
                ($0.keys as NSString).size(withAttributes: [.font: keyFont]).width
            }.max() ?? 0
            let para = NSMutableParagraphStyle()
            para.tabStops = [NSTextTab(textAlignment: .left, location: ceil(keyWidth) + size)]
            para.lineSpacing = size * 0.18
            let out = NSMutableAttributedString()
            for (i, s) in sections.enumerated() {
                if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: textFont])) }
                out.append(NSAttributedString(string: s.title + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: .bold),
                    .foregroundColor: NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 1), .paragraphStyle: para]))
                for r in s.rows {
                    out.append(NSAttributedString(string: r.keys + "\t", attributes: [
                        .font: keyFont, .foregroundColor: NSColor.white, .paragraphStyle: para]))
                    out.append(NSAttributedString(string: r.text + "\n", attributes: [
                        .font: textFont, .foregroundColor: NSColor(white: 1, alpha: 0.78), .paragraphStyle: para]))
                }
            }
            return out
        }
    }

    var layout: Layout?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) } }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 16, yRadius: 16)
        NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 0.82).setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard let l = layout else { return }
        let pad = Layout.pad
        l.title.draw(at: NSPoint(x: pad, y: pad))
        var x = pad
        for (i, c) in l.columns.enumerated() {
            c.draw(with: NSRect(x: x, y: pad + l.titleHeight, width: l.columnWidths[i] + 4, height: bounds.height),
                   options: [.usesLineFragmentOrigin])
            x += l.columnWidths[i] + Layout.gap
        }
    }
}
