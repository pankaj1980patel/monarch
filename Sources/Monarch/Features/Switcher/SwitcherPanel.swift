import AppKit

/// One switcher tile.
struct SwitcherItem {
    let id: CGWindowID
    let appName: String
    let title: String
    let icon: NSImage?
    let onBuiltin: Bool        // screen dot colour: MacBook green, monitor blue
    let workspace: Int
    let workspaceShown: Bool
}

/// The ⌘Tab panel: Liquid Glass (macOS 26), icons in a row, screen dot and workspace badge on
/// each icon, the title under it, and a footer line for the selected window.
///
/// Created once at launch and kept hidden, so the first ⌘Tab shows without delay. Changing the
/// selection only redraws this one view.
@MainActor
final class SwitcherPanel {
    // Same proportions as the Hammerspoon switcher.
    enum G {
        static let pad: CGFloat = 24, cell: CGFloat = 116, icon: CGFloat = 84, titleH: CGFloat = 18
        static let legend: CGFloat = 24, footer: CGFloat = 34, radius: CGFloat = 34
        static let monitor = NSColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1)
        static let macbook = NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1)
    }

    let panel: NSPanel
    private let view = SwitcherView()
    private let glass: NSView

    /// Mouse: hovering a tile selects it, clicking picks it.
    var onHover: ((Int) -> Void)? { get { view.onHover } set { view.onHover = newValue } }
    var onClick: ((Int) -> Void)? { get { view.onClick } set { view.onClick = newValue } }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true

        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = G.radius
            g.tintColor = NSColor(white: 0.04, alpha: 0.55)    // dark tint keeps text readable on any wallpaper
            g.contentView = view
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.state = .active
            v.blendingMode = .behindWindow
            v.wantsLayer = true
            v.layer?.cornerRadius = G.radius
            v.layer?.masksToBounds = true
            view.autoresizingMask = [.width, .height]
            v.addSubview(view)
            glass = v
        }
        panel.contentView = glass
    }

    var isVisible: Bool { panel.isVisible }

    /// Lays out `items` centred on `screenFrame` (Cocoa coordinates) without showing it.
    func load(_ items: [SwitcherItem], selected: Int, screenFrame: NSRect, twoScreens: Bool) {
        let n = CGFloat(max(items.count, 1))
        let scale = min(1, (screenFrame.width * 0.92 - G.pad * 2) / (n * G.cell))
        let cell = G.cell * scale
        let top = twoScreens ? G.legend : 0
        let tileH = cell + G.titleH
        let w = n * cell + G.pad * 2
        let h = top + tileH + G.pad * 2 + G.footer
        let frame = NSRect(x: (screenFrame.midX - w / 2).rounded(), y: (screenFrame.midY - h / 2).rounded(), width: w, height: h)
        panel.setFrame(frame, display: false)
        glass.frame = NSRect(origin: .zero, size: frame.size)
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.configure(items: items, selected: selected, cell: cell, iconSize: G.icon * scale, top: top, tileH: tileH)
    }

    func select(_ index: Int) { view.select(index) }

    /// Draws the tiles now (while hidden), so showing it later costs no drawing.
    func drawNow() { view.displayIfNeeded() }

    /// Shows the panel once, invisibly, so the first real ⌘Tab doesn't pay for macOS creating
    /// the window's backing and the glass effect.
    func prewarm() {
        panel.alphaValue = 0
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 100), display: false)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    /// Screen rect of the panel in AX coordinates is not needed: clicks arrive through the view.
    func contains(screenPoint p: NSPoint) -> Bool { panel.isVisible && panel.frame.contains(p) }
}

/// Draws the tiles. Flipped, so y grows downwards like the Hammerspoon layout.
@MainActor
private final class SwitcherView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private var items: [SwitcherItem] = []
    private var selected = 0
    private var cell: CGFloat = 116, iconSize: CGFloat = 84, top: CGFloat = 0, tileH: CGFloat = 134
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(items: [SwitcherItem], selected: Int, cell: CGFloat, iconSize: CGFloat, top: CGFloat, tileH: CGFloat) {
        self.items = items
        self.selected = selected
        self.cell = cell
        self.iconSize = iconSize
        self.top = top
        self.tileH = tileH
        needsDisplay = true
        updateTrackingAreas()
    }

    /// Repaints only the old and new tile and the footer, not every tile and its shadow.
    func select(_ i: Int) {
        guard i != selected else { return }
        let old = selected
        selected = i
        setNeedsDisplay(column(old))
        setNeedsDisplay(column(i))
        setNeedsDisplay(footerRect)
    }

    /// Tile `i` from the top of the selection highlight to the bottom of its title.
    private func column(_ i: Int) -> NSRect {
        let G = SwitcherPanel.G.self
        return NSRect(x: G.pad + CGFloat(i) * cell - 2, y: G.pad + top - 8, width: cell + 4, height: tileH + 14)
    }

    private var footerRect: NSRect {
        let G = SwitcherPanel.G.self
        return NSRect(x: G.pad, y: G.pad + top + tileH + 8, width: bounds.width - G.pad * 2, height: G.footer)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func index(at p: NSPoint) -> Int? {
        let G = SwitcherPanel.G.self
        let x = p.x - G.pad, y = p.y - G.pad - top + 4
        guard x >= 0, y >= 0, y <= tileH + 6 else { return nil }
        let i = Int(x / cell)
        return i < items.count ? i : nil
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClick?(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let G = SwitcherPanel.G.self
        guard !items.isEmpty else { return }

        // Legend: which dot colour is which screen.
        if top > 0 {
            let lx = G.pad + 4, ly: CGFloat = 12
            dot(at: NSPoint(x: lx + 4, y: ly + 7), r: 3.5, color: G.monitor, ring: false)
            text("Monitor", at: NSRect(x: lx + 12, y: ly, width: 60, height: 16), size: 11, weight: .regular, alpha: 0.5, align: .left)
            dot(at: NSPoint(x: lx + 78, y: ly + 7), r: 3.5, color: G.macbook, ring: false)
            text("MacBook", at: NSRect(x: lx + 86, y: ly, width: 70, height: 16), size: 11, weight: .regular, alpha: 0.5, align: .left)
        }

        // Selection.
        let sel = NSRect(x: G.pad + CGFloat(selected) * cell, y: G.pad + top - 4, width: cell, height: tileH + 6)
        let selPath = NSBezierPath(roundedRect: sel, xRadius: 20, yRadius: 20)
        NSColor(white: 1, alpha: 0.13).setFill(); selPath.fill()
        NSColor(white: 1, alpha: 0.22).setStroke(); selPath.lineWidth = 1; selPath.stroke()

        for (i, item) in items.enumerated() where column(i).intersects(dirtyRect) {
            let cx = G.pad + CGFloat(i) * cell, iy = G.pad + top
            let ix = cx + (cell - iconSize) / 2
            let iconRect = NSRect(x: ix, y: iy + (cell - iconSize) / 2 - 2, width: iconSize, height: iconSize)
            if let icon = item.icon {
                // The shadow is baked into the cached bitmap (AppIcons): a plain image copy here.
                let m = AppIcons.shadowMargin * (iconSize / SwitcherPanel.G.icon)
                icon.draw(in: iconRect.insetBy(dx: -m, dy: -m), from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            }
            let screenColor = item.onBuiltin ? G.macbook : G.monitor
            if top > 0 {                                                     // screen dot, top-right
                dot(at: NSPoint(x: iconRect.maxX - 9 * 0.4, y: iconRect.minY + 2 + 9 * 0.3), r: 4.5, color: screenColor, ring: true)
            }
            // Workspace badge, bottom-left, in the screen's colour; faded when hidden.
            let badge = NSRect(x: ix - 3, y: iconRect.maxY - 18, width: 20, height: 18)
            let bp = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
            screenColor.withAlphaComponent(item.workspaceShown ? 0.95 : 0.45).setFill(); bp.fill()
            NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.9).setStroke(); bp.lineWidth = 1.5; bp.stroke()
            text("\(item.workspace)", at: badge.offsetBy(dx: 0, dy: 1.5), size: 11.5, weight: .bold,
                 alpha: item.workspaceShown ? 1 : 0.8, align: .center)
            // Title under the icon.
            let t = item.title.isEmpty ? item.appName : item.title
            text(t, at: NSRect(x: cx + 6, y: iy + cell - 2, width: cell - 12, height: G.titleH),
                 size: 10.5, weight: .regular, alpha: i == selected ? 1 : 0.5, align: .center)
        }

        // Footer: app name, title, workspace.
        guard footerRect.intersects(dirtyRect) else { return }
        let s = items[selected]
        let footer = NSMutableAttributedString()
        let para = Self.paragraph(.center)
        footer.append(NSAttributedString(string: s.appName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor(white: 1, alpha: 0.98)]))
        if !s.title.isEmpty && s.title != s.appName {
            footer.append(NSAttributedString(string: "   " + s.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.55)]))
        }
        footer.append(NSAttributedString(string: "   ·  workspace \(s.workspace)" + (s.workspaceShown ? "" : " (hidden)"), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: s.workspaceShown ? NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 1) : NSColor(white: 1, alpha: 0.45)]))
        footer.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: footer.length))
        footer.draw(with: NSRect(x: G.pad, y: G.pad + top + tileH + 12, width: bounds.width - G.pad * 2, height: G.footer - 10),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func dot(at c: NSPoint, r: CGFloat, color: NSColor, ring: Bool) {
        let p = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        color.setFill(); p.fill()
        if ring { NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 0.9).setStroke(); p.lineWidth = 2; p.stroke() }
    }

    /// Truncating paragraph styles, built once per alignment.
    private static let paragraphs: [NSTextAlignment: NSParagraphStyle] = {
        var out: [NSTextAlignment: NSParagraphStyle] = [:]
        for a in [NSTextAlignment.left, .center, .right] {
            let p = NSMutableParagraphStyle()
            p.alignment = a
            p.lineBreakMode = .byTruncatingTail
            out[a] = p
        }
        return out
    }()
    private static func paragraph(_ a: NSTextAlignment) -> NSParagraphStyle { paragraphs[a] ?? paragraphs[.left]! }


    private func text(_ s: String, at r: NSRect, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, align: NSTextAlignment) {
        (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .paragraphStyle: Self.paragraph(align),
        ])
    }
}
