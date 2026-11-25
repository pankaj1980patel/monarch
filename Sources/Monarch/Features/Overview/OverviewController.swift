import AppKit
import MonarchCore

/// The custom Mission Control: every display shows its own workspaces as cards listing their
/// windows, plus a "+" card for the next empty workspace.
///
/// - Click a window: go to its workspace and focus it. Click a card: switch to it.
///   Click empty space or right-click: close. Drag a window onto a card (any display): move it.
/// - ← → ↑ ↓ select; ⇧ ← / → moves the selected window one card; hold Space + arrows carries
///   it (release Space to drop); ↩ goes; Space on a card switches; 1–9 switch; Esc closes
///   (drops a carried window first).
///
/// Input is native: the panels take the keyboard without activating Monarch (non-activating,
/// key-capable panels) and clicks land on the panels themselves, so nothing underneath is
/// clicked and no event tap is needed. Metadata only: no screenshots, no Screen Recording.
@MainActor
final class OverviewController {
    private let engine: WindowEngine
    private let displays: DisplayManager
    private let workspaces: WorkspaceManager
    private let perf: PerformanceMonitor
    private let bridge: HammerspoonBridge

    fileprivate struct Screen {
        let display: Display
        let cards: [OverviewModel.Card]
        let layout: OverviewModel.Layout
        let panel: OverviewPanel
        /// Rows actually drawn per card (fewer than windows when a "+N more" line is needed).
        let shownRows: [Int]
    }
    private var screens: [Screen] = []
    private var panels: [UInt32: OverviewPanel] = [:]     // reused per display id
    private(set) var isOpen = false

    fileprivate var selection = OverviewModel.Selection(screen: 0, card: 0, row: 0)
    fileprivate var grabbed: CGWindowID?
    fileprivate var dropTarget: (screen: Int, card: Int)?
    private var keepWindow: CGWindowID?
    private var openedAt: Double = 0
    private var gestureActive = false
    private var guardUntil: Double = 0
    private var refreshWork: DispatchWorkItem?
    private var iconCache: [pid_t: NSImage] = [:]
    /// A three-finger swipe is driving the overview (nil otherwise). `opening`: it started closed.
    private var interaction: (opening: Bool, progress: Double)?
    var isInteracting: Bool { interaction != nil }

    init(engine: WindowEngine, displays: DisplayManager, workspaces: WorkspaceManager,
         perf: PerformanceMonitor, bridge: HammerspoonBridge) {
        self.engine = engine
        self.displays = displays
        self.workspaces = workspaces
        self.perf = perf
        self.bridge = bridge
        // Window frames settle a moment after moves: refresh (coalesced) while open.
        engine.onUpdate { [unowned self] _ in if isOpen { scheduleRefresh() } }
        engine.onRemove { [unowned self] _ in if isOpen { scheduleRefresh() } }
    }

    // MARK: Open / close

    func toggle(eventTime: Double) { isOpen ? close() : open(eventTime: eventTime) }

    func open(eventTime: Double) {
        if interaction != nil { endInteractive(open: true, velocity: 0); return }
        guard !isOpen else { return }
        isOpen = true
        openedAt = PerformanceMonitor.now()
        grabbed = nil
        dropTarget = nil
        rebuild(initialSelection: true)
        for s in screens { s.panel.show(animated: true) }
        // Keyboard goes to the panel on the mouse's display.
        let mouse = AutoFocusManager.cursor()
        (screens.first { $0.display.frame.contains(mouse) } ?? screens.first)?.panel.makeKey()
        bridge.overviewChanged(open: true)
        perf.record("14 overview: open → shown", since: eventTime)
    }

    func close() {
        if interaction != nil { endInteractive(open: false, velocity: 0); return }
        guard isOpen else { return }
        isOpen = false
        grabbed = nil
        refreshWork?.cancel()
        for s in screens { s.panel.hide() }
        bridge.overviewChanged(open: false)
    }

    // MARK: Interactive (three-finger swipe)

    /// A swipe starts driving the overview: opening if it's closed, closing if it's open.
    /// Returns whether it is opening.
    @discardableResult
    func beginInteractive() -> Bool {
        if let i = interaction { return i.opening }
        let opening = !isOpen
        if opening {
            isOpen = true
            openedAt = PerformanceMonitor.now()
            grabbed = nil
            dropTarget = nil
            rebuild(initialSelection: true)
            for s in screens { s.panel.prepareInteractive(visibility: 0) }
        } else {
            for s in screens { s.panel.prepareInteractive(visibility: 1) }
        }
        interaction = (opening, opening ? 0 : 1)
        return opening
    }

    /// `visibility` 0 (closed) … 1 (open), straight from the fingers (display link, main thread).
    func setInteractive(visibility v: Double) {
        guard interaction != nil else { return }
        let c = min(max(v, 0), 1)
        interaction?.progress = c
        for s in screens { s.panel.setVisibility(c) }
    }

    /// The fingers lifted: finish to open or closed with a spring that starts at the fingers' speed.
    /// `velocity` is in visibility per second (toward open positive).
    func endInteractive(open target: Bool, velocity: Double) {
        guard let i = interaction else { return }
        interaction = nil
        for s in screens { s.panel.finish(visible: target, from: i.progress, velocity: velocity) }
        if target {
            let mouse = AutoFocusManager.cursor()
            (screens.first { $0.display.frame.contains(mouse) } ?? screens.first)?.panel.makeKey()
            if i.opening {
                openedAt = PerformanceMonitor.now()
                bridge.overviewChanged(open: true)
            }
        } else {
            isOpen = false
            grabbed = nil
            refreshWork?.cancel()
            if !i.opening { bridge.overviewChanged(open: false) }
        }
    }

    /// Workspace state changed (a move finished, a window closed, a display changed).
    func refreshIfOpen() { if isOpen { scheduleRefresh() } }

    /// Hammerspoon's gesture code: fingers down / all lifted. With tap-to-click on, lifting
    /// three fingers after the swipe that opened the overview registers as a click.
    func gesture(active: Bool, guardSeconds: Double = 0.35) {
        gestureActive = active
        if !active { guardUntil = PerformanceMonitor.now() + guardSeconds }
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isOpen else { return }
            self.rebuild(initialSelection: false)
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: Model

    private func rebuild(initialSelection: Bool) {
        let state = workspaces.state
        let list = displays.displays.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        var built: [Screen] = []
        for d in list {
            let parked = state.hidden.compactMap { k, e -> (id: UInt32, ws: Int, z: Int)? in
                guard e.scr == d.uuid, let id = UInt32(k), engine.windows[id] != nil else { return nil }
                return (id, e.ws, e.z)
            }
            let cards = OverviewModel.cards(active: state.activeWorkspace(d.uuid),
                                            visible: workspaces.visibleWindows(on: d), parked: parked)
            let layout = OverviewModel.layout(cardCount: cards.count, size: d.frame.size)
            let shown = cards.map { $0.windows.count <= layout.maxRows ? $0.windows.count : max(0, layout.maxRows - 1) }
            let panel = panels[d.id] ?? OverviewPanel(controller: self)
            panels[d.id] = panel
            built.append(Screen(display: d, cards: cards, layout: layout, panel: panel, shownRows: shown))
        }
        // Panels of displays that went away.
        let ids = Set(list.map(\.id))
        for (id, p) in panels where !ids.contains(id) { p.hide(); panels.removeValue(forKey: id) }
        screens = built

        if let keep = keepWindow, let sel = find(keep) { selection = sel; keepWindow = nil }
        else if initialSelection || !isValid(selection) { selection = defaultSelection() }

        for (i, s) in screens.enumerated() {
            s.panel.load(display: s.display, content: content(for: i))
        }
    }

    fileprivate func content(for i: Int) -> OverviewContent {
        let s = screens[i]
        let cards = s.cards.enumerated().map { ci, card -> OverviewContent.CardContent in
            let rows = card.windows.prefix(s.shownRows[ci]).map { id -> OverviewContent.Row in
                let w = engine.windows[id]
                let app = w.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
                return .init(id: id, appName: app?.localizedName ?? "?", title: w?.title ?? "", icon: icon(w?.pid))
            }
            return .init(frame: s.layout.cardFrames[ci], card: card, rows: rows,
                         more: card.windows.count - s.shownRows[ci],
                         isDropTarget: dropTarget.map { $0.screen == i && $0.card == ci } ?? false)
        }
        var sel: OverviewContent.SelectionMark?
        if selection.screen == i, selection.card < s.cards.count {
            let carrying = grabbed != nil && selection.row > 0
            sel = .init(card: selection.card, row: selection.row, carrying: carrying)
        }
        return OverviewContent(name: s.display.name, cards: cards, layout: s.layout, selection: sel)
    }

    private func icon(_ pid: pid_t?) -> NSImage? {
        guard let pid else { return nil }
        if let i = iconCache[pid] { return i }
        let i = NSRunningApplication(processIdentifier: pid)?.icon
        iconCache[pid] = i
        return i
    }

    private func isValid(_ s: OverviewModel.Selection) -> Bool {
        s.screen < screens.count && s.card < screens[s.screen].cards.count && s.row <= screens[s.screen].shownRows[s.card]
    }

    /// The focused window if it's on the mouse's display, else that display's active card.
    private func defaultSelection() -> OverviewModel.Selection {
        let mouse = AutoFocusManager.cursor()
        let si = screens.firstIndex { $0.display.frame.contains(mouse) } ?? 0
        guard si < screens.count else { return .init(screen: 0, card: 0, row: 0) }
        if let f = engine.focusedID, let sel = find(f), sel.screen == si { return sel }
        let ci = screens[si].cards.firstIndex { $0.isActive } ?? 0
        return .init(screen: si, card: ci, row: 0)
    }

    private func find(_ id: CGWindowID) -> OverviewModel.Selection? {
        for (si, s) in screens.enumerated() {
            for (ci, c) in s.cards.enumerated() {
                if let ri = c.windows.prefix(s.shownRows[ci]).firstIndex(of: id) { return .init(screen: si, card: ci, row: ri + 1) }
            }
        }
        return nil
    }

    private func selectedWindow() -> CGWindowID? {
        guard isValid(selection), selection.row > 0 else { return nil }
        return screens[selection.screen].cards[selection.card].windows[selection.row - 1]
    }

    private func redrawSelection() {
        for (i, s) in screens.enumerated() { s.panel.update(content: content(for: i)) }
    }

    // MARK: Keyboard

    /// Returns true if handled.
    fileprivate func key(_ e: NSEvent, down: Bool) -> Bool {
        let code = Int(e.keyCode)
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if !down {
            if code == 49, grabbed != nil { grabbed = nil; redrawSelection(); return true }   // Space up: drop
            return false
        }
        if code == 53 {                                                                       // Esc
            if grabbed != nil { grabbed = nil; redrawSelection() } else { close() }
            return true
        }
        guard mods.isEmpty else { return false }
        let shift = e.modifierFlags.contains(.shift)
        let held = grabbed != nil
        switch code {
        case 123: held || shift ? shiftWindow(dx: -1, dy: 0) : moveSelection(dx: -1, dy: 0)
        case 124: held || shift ? shiftWindow(dx: 1, dy: 0) : moveSelection(dx: 1, dy: 0)
        case 126: held ? shiftWindow(dx: 0, dy: -1) : moveSelection(dx: 0, dy: -1)
        case 125: held ? shiftWindow(dx: 0, dy: 1) : moveSelection(dx: 0, dy: 1)
        case 49:                                                                              // Space: hold to carry
            if e.isARepeat || held { return true }
            if let id = selectedWindow() { grabbed = id; redrawSelection() }
            else if isValid(selection) { goCard(selection.screen, selection.card) }
        case 36, 76:                                                                          // ↩ / keypad enter
            if let id = selectedWindow() { goWindow(id) }
            else if isValid(selection) { goCard(selection.screen, selection.card) }
        default:
            if let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...9).contains(n) {
                let mouse = AutoFocusManager.cursor()
                if let d = displays.displays.first(where: { $0.frame.contains(mouse) }) {
                    close()
                    workspaces.switchTo(n, on: d, eventTime: PerformanceMonitor.now())
                }
                return true
            }
            return false
        }
        return true
    }

    private func moveSelection(dx: Int, dy: Int) {
        if !isValid(selection) { selection = defaultSelection() }
        selection = OverviewModel.move(selection, dx: dx, dy: dy, cards: screens.map(\.cards.count),
                                       rows: screens.map(\.shownRows), cols: screens.map(\.layout.cols))
        redrawSelection()
    }

    /// Moves the selected window to the neighbouring card (← →, crossing displays) or the card
    /// above / below; the selection follows the window.
    private func shiftWindow(dx: Int, dy: Int) {
        guard let id = selectedWindow() else { return }
        let from = selection
        var to = selection
        if dy != 0 {
            let c2 = from.card + dy * screens[from.screen].layout.cols
            guard c2 >= 0, c2 < screens[from.screen].cards.count else { return }
            to = .init(screen: from.screen, card: c2, row: 0)
        } else {
            to = OverviewModel.move(.init(screen: from.screen, card: from.card, row: 0), dx: dx, dy: 0,
                                    cards: screens.map(\.cards.count), rows: screens.map(\.shownRows),
                                    cols: screens.map(\.layout.cols))
        }
        guard (to.screen, to.card) != (from.screen, from.card) else { return }
        let target = screens[to.screen]
        keepWindow = id
        workspaces.place(id, on: target.display, workspace: target.cards[to.card].workspace)
        rebuild(initialSelection: false)                 // state changed synchronously; frames follow
    }

    // MARK: Mouse

    private var down: (point: CGPoint, screen: Int, card: Int?, window: CGWindowID?)?

    /// `p` is in AX (global, top-left) coordinates.
    fileprivate func mouseDown(at p: CGPoint, right: Bool) {
        if clickGuarded() { down = nil; return }
        if right { close(); return }
        let hit = hitTest(p)
        down = (p, hit?.screen ?? 0, hit?.card, hit?.window)
    }

    fileprivate func mouseDragged(to p: CGPoint) {
        guard let d = down, d.window != nil else { return }
        let hit = hitTest(p)
        let target = hit.flatMap { h in h.card.map { (h.screen, $0) } }
        if target?.0 != dropTarget?.screen || target?.1 != dropTarget?.card {
            dropTarget = target
            redrawSelection()
        }
        _ = d
    }

    fileprivate func mouseUp(at p: CGPoint) {
        guard let d = down else { return }
        down = nil
        let hadDrop = dropTarget != nil
        dropTarget = nil
        let moved = abs(p.x - d.point.x) + abs(p.y - d.point.y) > 8
        let hit = hitTest(p)
        if let id = d.window, moved, let h = hit, let c = h.card {                        // drag & drop
            let s = screens[h.screen]
            keepWindow = id
            workspaces.place(id, on: s.display, workspace: s.cards[c].workspace)
            rebuild(initialSelection: false)
            return
        }
        if hadDrop { redrawSelection() }
        guard let h = hit, let c = h.card else { close(); return }                       // empty space
        if let id = h.window { goWindow(id) } else { goCard(h.screen, c) }
    }

    private func clickGuarded() -> Bool {
        let now = PerformanceMonitor.now()
        return gestureActive || now - openedAt < 0.4 || now < guardUntil
    }

    private func hitTest(_ p: CGPoint) -> (screen: Int, card: Int?, window: CGWindowID?)? {
        for (si, s) in screens.enumerated() where s.display.frame.contains(p) {
            let local = CGPoint(x: p.x - s.display.frame.minX, y: p.y - s.display.frame.minY)
            for (ci, f) in s.layout.cardFrames.enumerated() where f.contains(local) {
                let r = Int((local.y - f.minY - s.layout.rowsTop) / s.layout.rowHeight)
                let rowY = local.y - f.minY - s.layout.rowsTop
                if rowY >= 0, r < s.shownRows[ci] { return (si, ci, s.cards[ci].windows[r]) }
                return (si, ci, nil)
            }
            return (si, nil, nil)
        }
        return nil
    }

    // MARK: Actions

    private func goWindow(_ id: CGWindowID) {
        close()
        workspaces.reveal(id)              // switches workspace if parked, then focuses only that window
    }

    private func goCard(_ screen: Int, _ card: Int) {
        let s = screens[screen]
        close()
        workspaces.switchTo(s.cards[card].workspace, on: s.display, eventTime: PerformanceMonitor.now())
    }
}

// MARK: - Panel and view

/// What one display's overview draws.
struct OverviewContent {
    struct Row { let id: CGWindowID; let appName: String; let title: String; let icon: NSImage? }
    struct CardContent { let frame: CGRect; let card: OverviewModel.Card; let rows: [Row]; let more: Int; let isDropTarget: Bool }
    struct SelectionMark { let card: Int; let row: Int; let carrying: Bool }
    let name: String
    let cards: [CardContent]
    let layout: OverviewModel.Layout
    let selection: SelectionMark?
}

/// Borderless panels can't normally become key; this one can, without activating Monarch.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OverviewPanel {
    private let panel: KeyPanel
    private let view: OverviewView

    init(controller: OverviewController) {
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        view = OverviewView(controller: controller)
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        panel.contentView = blur
    }

    func load(display: Display, content: OverviewContent) {
        let screen = SwitcherController.cocoaScreen(for: display.id)
        panel.setFrame(screen?.frame ?? .zero, display: false)
        view.frame = panel.contentView?.bounds ?? .zero
        view.content = content
        view.needsDisplay = true
    }

    func update(content: OverviewContent) {
        view.content = content
        view.needsDisplay = true
    }

    /// Bumped by every show / hide / finish so an old animation's completion can't hide a
    /// panel that was opened again meanwhile.
    private var generation = 0

    func show(animated: Bool) {
        generation += 1
        resetTransform()
        panel.alphaValue = animated ? 0 : 1
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func makeKey() { panel.makeKey(); panel.makeFirstResponder(view) }
    func hide() { generation += 1; resetTransform(); panel.orderOut(nil) }

    // Interactive: window alpha plus a slight zoom of the content (1.04 → 1 as it opens).

    func prepareInteractive(visibility: Double) {
        generation += 1
        if let l = layer { l.removeAllAnimations() }
        setVisibility(visibility)
        panel.orderFrontRegardless()
    }

    func setVisibility(_ v: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.alphaValue = CGFloat(v)
        layer?.sublayerTransform = zoom(v)
        CATransaction.commit()
    }

    func finish(visible: Bool, from v: Double, velocity: Double) {
        generation += 1
        let gen = generation
        let target = visible ? 1.0 : 0.0
        let remaining = abs(target - v)
        guard remaining > 0.001 else {
            setVisibility(target)
            if !visible { hide() }
            return
        }
        // Critically damped spring, started at the fingers' speed (in units of the remaining distance).
        let spring = CASpringAnimation(keyPath: "sublayerTransform")
        spring.mass = 1; spring.stiffness = 300; spring.damping = 2 * (300.0).squareRoot()
        spring.initialVelocity = CGFloat(max(0, min(abs(velocity) / remaining, 20)))
        spring.fromValue = NSValue(caTransform3D: zoom(v))
        spring.toValue = NSValue(caTransform3D: zoom(target))
        let duration = min(spring.settlingDuration, 0.35)
        spring.duration = duration
        layer?.sublayerTransform = zoom(target)
        layer?.add(spring, forKey: "zoom")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration * 0.8
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)
            panel.animator().alphaValue = CGFloat(target)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen, !visible else { return }
                self.hide()
            }
        })
    }

    private var layer: CALayer? {
        guard let v = panel.contentView else { return nil }
        if !v.wantsLayer { v.wantsLayer = true }
        return v.layer
    }

    private func zoom(_ v: Double) -> CATransform3D {
        guard let b = panel.contentView?.bounds, b.width > 0 else { return CATransform3DIdentity }
        let s = CGFloat(1.04 - 0.04 * v)
        // Layer-backed views anchor at (0, 0): scale around the centre.
        var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -b.midX, -b.midY, 0)
    }

    private func resetTransform() {
        layer?.removeAllAnimations()
        layer?.sublayerTransform = CATransform3DIdentity
    }
}

@MainActor
private final class OverviewView: NSView {
    unowned let controller: OverviewController
    var content: OverviewContent?

    init(controller: OverviewController) {
        self.controller = controller
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) { if !controller.key(event, down: true) { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { if !controller.key(event, down: false) { super.keyUp(with: event) } }
    override func mouseDown(with event: NSEvent) { controller.mouseDown(at: Self.axMouse(), right: false) }
    override func rightMouseDown(with event: NSEvent) { controller.mouseDown(at: Self.axMouse(), right: true) }
    override func mouseDragged(with event: NSEvent) { controller.mouseDragged(to: Self.axMouse()) }
    override func mouseUp(with event: NSEvent) { controller.mouseUp(at: Self.axMouse()) }

    /// Cursor in AX coordinates, valid across displays even mid-drag.
    static func axMouse() -> CGPoint { AutoFocusManager.cursor() }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = content else { return }
        NSColor(red: 0.03, green: 0.035, blue: 0.05, alpha: 0.55).setFill()
        bounds.fill()

        // Header: display name + hint.
        let header = NSMutableAttributedString(string: c.name + "   ", attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white])
        header.append(NSAttributedString(string: "click / ↩ go · drag, or hold Space + arrows, to move a window · Esc close", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.55)]))
        header.draw(with: NSRect(x: 44, y: 34, width: bounds.width - 88, height: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        for (ci, card) in c.cards.enumerated() {
            let f = card.frame
            let path = NSBezierPath(roundedRect: f, xRadius: 16, yRadius: 16)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
            shadow.set()
            (card.card.isActive ? NSColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 0.92)
                                : NSColor(red: 0.11, green: 0.115, blue: 0.14, alpha: 0.92)).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            if card.isDropTarget {
                NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1).setStroke(); path.lineWidth = 2.5
            } else if card.card.isActive {
                NSColor(red: 0.35, green: 0.6, blue: 1, alpha: 0.95).setStroke(); path.lineWidth = 2
            } else {
                NSColor(white: 1, alpha: 0.12).setStroke(); path.lineWidth = 1
            }
            path.stroke()

            let n = card.card.windows.count
            let head = NSMutableAttributedString(string: (card.card.isPlus ? "+" : "\(card.card.workspace)") + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white])
            let sub = card.card.isPlus ? "drop here → workspace \(card.card.workspace)"
                : "\(n) window\(n == 1 ? "" : "s")" + (card.card.isActive ? "  ·  active" : "")
            head.append(NSAttributedString(string: sub, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.6)]))
            head.draw(with: NSRect(x: f.minX + 18, y: f.minY + 12, width: f.width - 36, height: 34),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            var ry = f.minY + c.layout.rowsTop
            for row in card.rows {
                let rr = NSRect(x: f.minX + 10, y: ry, width: f.width - 20, height: c.layout.rowHeight - 4)
                NSColor(white: 1, alpha: 0.05).setFill()
                NSBezierPath(roundedRect: rr, xRadius: 9, yRadius: 9).fill()
                row.icon?.draw(in: NSRect(x: f.minX + 16, y: ry + 4, width: 28, height: 28), from: .zero,
                               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let t = NSMutableAttributedString(string: row.appName + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
                if row.title != row.appName {
                    t.append(NSAttributedString(string: row.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.6)]))
                }
                t.draw(with: NSRect(x: f.minX + 52, y: ry + 9, width: f.width - 70, height: 20),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                ry += c.layout.rowHeight
            }
            if card.more > 0 {
                ("+\(card.more) more" as NSString).draw(in: NSRect(x: f.minX + 18, y: ry + 10, width: f.width - 36, height: 20), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.5)])
            }

            if let s = c.selection, s.card == ci {
                let r = s.row > 0
                    ? NSRect(x: f.minX + 7, y: f.minY + c.layout.rowsTop + CGFloat(s.row - 1) * c.layout.rowHeight - 3,
                             width: f.width - 14, height: c.layout.rowHeight + 2)
                    : f.insetBy(dx: 3, dy: 3)
                let p = NSBezierPath(roundedRect: r, xRadius: 11, yRadius: 11)
                (s.carrying ? NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1) : NSColor(white: 1, alpha: 0.95)).setStroke()
                p.lineWidth = 2.5
                p.stroke()
            }
        }
    }
}
