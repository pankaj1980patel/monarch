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
    /// Bumped whenever the cards themselves change (rebuild); selection-only updates keep it,
    /// so panels redraw just the selection instead of the whole screen.
    private var contentVersion = 0
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
        engine.onUpdate { [unowned self] _ in stateChanged() }
        engine.onRemove { [unowned self] _ in stateChanged() }
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
        // Timed when Core Animation has committed the first frame, not right after orderFront.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [perf] in perf.record("14 overview: open → first frame", since: eventTime) }
        for s in screens { s.panel.show(animated: true) }
        CATransaction.commit()
        // Keyboard goes to the panel on the mouse's display.
        let mouse = AutoFocusManager.cursor()
        (screens.first { $0.display.frame.contains(mouse) } ?? screens.first)?.panel.makeKey()
        bridge.overviewChanged(open: true)
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
    func refreshIfOpen() { stateChanged() }

    /// Windows or workspaces changed. Open: refresh soon. Closed: prepare the cards in the
    /// background (batched, at most once a second), so opening only swaps in images that are
    /// already rendered.
    private func stateChanged() {
        if isOpen { scheduleRefresh(); return }
        guard prerenderWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.prerenderWork = nil
            if !self.isOpen && self.workspaces.isActive { self.rebuild(initialSelection: true) }
        }
        prerenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    private var prerenderWork: DispatchWorkItem?

    /// Shortly after launch: build the panels and their cards, and have WindowServer create
    /// the windows and blur, so the first open costs what every open costs.
    func prewarm() {
        guard !isOpen, workspaces.isActive else { return }
        rebuild(initialSelection: true)
        for s in screens { s.panel.prewarm() }
    }

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
        let z = AutoFocusManager.zOrder()                        // one window-list fetch for all displays
        var built: [Screen] = []
        for d in list {
            let parked = state.hidden.compactMap { k, e -> (id: UInt32, ws: Int, z: Int)? in
                guard e.scr == d.uuid, let id = UInt32(k), engine.windows[id] != nil else { return nil }
                return (id, e.ws, e.z)
            }
            let cards = OverviewModel.cards(active: state.activeWorkspace(d.uuid),
                                            visible: workspaces.visibleWindows(on: d, zOrder: z), parked: parked)
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
        contentVersion &+= 1

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
                let name = w.flatMap { engine.apps[$0.pid]?.name } ?? "?"     // stored when the app was tracked
                return .init(id: id, appName: name, title: w?.title ?? "", icon: icon(w?.pid))
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
        return OverviewContent(name: s.display.name, cards: cards, layout: s.layout, selection: sel, version: contentVersion)
    }

    /// Shared cache of small bitmaps at the row icon size (dropped when the app quits).
    private func icon(_ pid: pid_t?) -> NSImage? { pid.flatMap { AppIcons.icon($0, points: 28) } }

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
    struct SelectionMark: Equatable { let card: Int; let row: Int; let carrying: Bool }
    let name: String
    let cards: [CardContent]
    let layout: OverviewModel.Layout
    let selection: SelectionMark?
    /// Same version = same cards; only the selection or drop target can differ.
    let version: Int
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
        // defer: false, so the window exists now (prewarm) instead of at the first open.
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        // Layer-backed from the start: switching it on during the first show (the interactive
        // zoom needs the layer) made the very first open after launch come up blank.
        blur.wantsLayer = true
        view = OverviewView(controller: controller)
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        panel.contentView = blur
    }

    func load(display: Display, content: OverviewContent) {
        let screen = SwitcherController.cocoaScreen(for: display.id)
        let frame = screen?.frame ?? .zero
        if panel.frame != frame {                          // refreshes while open: usually unchanged
            panel.setFrame(frame, display: false)
            view.frame = panel.contentView?.bounds ?? .zero
        }
        view.apply(content, scale: screen?.backingScaleFactor ?? 2)
    }

    /// Selection and drop-target changes: the ring moves, a border changes; nothing is redrawn.
    func update(content: OverviewContent) { view.apply(content, scale: panel.backingScaleFactor) }

    /// Shows the window once, invisibly, so WindowServer creates it and the blur now rather
    /// than on the first real open.
    func prewarm() {
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        panel.alphaValue = 1
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

/// One display's overview, built from layers so the GPU does the work:
/// - the tint is the view layer's background colour (no full-screen CPU drawing, no
///   full-screen backing image);
/// - each card is a layer with a corner radius, a border and a shadow from a `shadowPath`
///   (GPU shadow), holding one image of its text and icons — rendered once per card content
///   and cached, so an unchanged card is never redrawn;
/// - the selection ring is its own layer that moves.
/// Layer coordinates are bottom-left; the model's frames are top-left, so y is flipped here.
@MainActor
private final class OverviewView: NSView {
    unowned let controller: OverviewController
    private(set) var content: OverviewContent?

    private let header = CALayer()
    private var headerKey: String?
    private var cardLayers: [CALayer] = []          // card (background, border, shadow)
    private var imageLayers: [CALayer] = []         // its text + icons
    private let ring = CAShapeLayer()
    /// Rendered card images by content (pruned to the cards currently shown).
    private var images: [CardKey: CGImage] = [:]
    private var imageKeys: [CardKey?] = []

    private static let tint = CGColor(red: 0.03, green: 0.035, blue: 0.05, alpha: 0.55)
    private static let activeFill = CGColor(red: 0.10, green: 0.16, blue: 0.28, alpha: 0.92)
    private static let fill = CGColor(red: 0.11, green: 0.115, blue: 0.14, alpha: 0.92)
    private static let green = CGColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1)
    private static let blue = CGColor(red: 0.35, green: 0.6, blue: 1, alpha: 0.95)
    private static let faint = CGColor(gray: 1, alpha: 0.12)

    init(controller: OverviewController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        header.anchorPoint = .zero
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.anchorPoint = .zero
        ring.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Self.tint }
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

    // MARK: Layers

    func apply(_ c: OverviewContent, scale: CGFloat) {
        content = c
        guard let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.backgroundColor = Self.tint
        let H = bounds.height
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }

        // Header: display name + hint, rendered when the name or width changes.
        let hRect = CGRect(x: 44, y: 34, width: max(0, bounds.width - 88), height: 34)
        let hKey = "\(c.name)|\(Int(hRect.width))|\(scale)"
        if header.superlayer == nil { root.addSublayer(header) }
        if hKey != headerKey, let img = Self.renderHeader(c.name, size: hRect.size, scale: scale) {
            header.contents = img
            header.contentsScale = scale
            headerKey = hKey
        }
        header.frame = flip(hRect)

        // Cards.
        while cardLayers.count < c.cards.count {
            let card = CALayer()
            card.cornerRadius = 16
            card.shadowColor = .black
            card.shadowOpacity = 0.45
            card.shadowRadius = 8
            card.shadowOffset = CGSize(width: 0, height: -3)
            let img = CALayer()
            img.anchorPoint = .zero
            card.addSublayer(img)
            root.insertSublayer(card, below: ring)
            cardLayers.append(card)
            imageLayers.append(img)
            imageKeys.append(nil)
        }
        if ring.superlayer == nil { root.addSublayer(ring) }
        for i in c.cards.count..<cardLayers.count { cardLayers[i].isHidden = true }

        var used = Set<CardKey>()
        for (i, card) in c.cards.enumerated() {
            let l = cardLayers[i]
            l.isHidden = false
            let f = flip(card.frame)
            if l.frame != f {
                l.frame = f
                l.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: f.size), cornerWidth: 16, cornerHeight: 16, transform: nil)
            }
            l.backgroundColor = card.card.isActive ? Self.activeFill : Self.fill
            if card.isDropTarget { l.borderColor = Self.green; l.borderWidth = 2.5 }
            else if card.card.isActive { l.borderColor = Self.blue; l.borderWidth = 2 }
            else { l.borderColor = Self.faint; l.borderWidth = 1 }

            let key = CardKey(card, layout: c.layout, scale: scale)
            used.insert(key)
            if imageKeys[i] != key {
                let img = images[key] ?? Self.renderCard(card, layout: c.layout, scale: scale)
                images[key] = img
                imageLayers[i].contents = img
                imageLayers[i].contentsScale = scale
                imageKeys[i] = key
            }
            imageLayers[i].frame = CGRect(origin: .zero, size: f.size)
        }
        images = images.filter { used.contains($0.key) }

        // Selection ring.
        if let s = c.selection, let r = Self.selectionRect(s, in: c) {
            let f = flip(r)
            ring.isHidden = false
            ring.strokeColor = s.carrying ? Self.green : CGColor(gray: 1, alpha: 0.95)
            if ring.frame.size != f.size {
                ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: f.size), cornerWidth: 11, cornerHeight: 11, transform: nil)
            }
            ring.frame = f
        } else {
            ring.isHidden = true
        }
        CATransaction.commit()
    }

    /// The selection ring: a row, or the whole card when row is 0 (top-left coordinates).
    static func selectionRect(_ s: OverviewContent.SelectionMark, in c: OverviewContent) -> CGRect? {
        guard s.card < c.cards.count else { return nil }
        let f = c.cards[s.card].frame
        return s.row > 0
            ? CGRect(x: f.minX + 7, y: f.minY + c.layout.rowsTop + CGFloat(s.row - 1) * c.layout.rowHeight - 3,
                     width: f.width - 14, height: c.layout.rowHeight + 2)
            : f.insetBy(dx: 3, dy: 3)
    }

    // MARK: Rendering (into card-sized bitmaps)

    /// What a card image depends on.
    struct CardKey: Hashable {
        let w: Int, h: Int, scale: Int
        let workspace: Int, isPlus: Bool, isActive: Bool, count: Int, more: Int
        let rows: [String]
        let rowsTop: Int, rowHeight: Int
        init(_ c: OverviewContent.CardContent, layout: OverviewModel.Layout, scale: CGFloat) {
            w = Int(c.frame.width); h = Int(c.frame.height); self.scale = Int(scale * 100)
            workspace = c.card.workspace; isPlus = c.card.isPlus; isActive = c.card.isActive
            count = c.card.windows.count; more = c.more
            rows = c.rows.map { "\($0.id)\u{1}\($0.appName)\u{1}\($0.title)" }
            rowsTop = Int(layout.rowsTop); rowHeight = Int(layout.rowHeight)
        }
    }

    /// Draws with a flipped (top-left) graphics context into a bitmap of `size` points.
    private static func render(size: CGSize, scale: CGFloat, _ draw: () -> Void) -> CGImage? {
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func renderHeader(_ name: String, size: CGSize, scale: CGFloat) -> CGImage? {
        render(size: size, scale: scale) {
            let header = NSMutableAttributedString(string: name + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white])
            header.append(NSAttributedString(string: "click / ↩ go · drag, or hold Space + arrows, to move a window · Esc close", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.55)]))
            header.draw(with: NSRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private static func renderCard(_ card: OverviewContent.CardContent, layout: OverviewModel.Layout, scale: CGFloat) -> CGImage? {
        let size = card.frame.size
        return render(size: size, scale: scale) {
            let w = size.width
            let n = card.card.windows.count
            let head = NSMutableAttributedString(string: (card.card.isPlus ? "+" : "\(card.card.workspace)") + "   ", attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white])
            let sub = card.card.isPlus ? "drop here → workspace \(card.card.workspace)"
                : "\(n) window\(n == 1 ? "" : "s")" + (card.card.isActive ? "  ·  active" : "")
            head.append(NSAttributedString(string: sub, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.6)]))
            head.draw(with: NSRect(x: 18, y: 12, width: w - 36, height: 34), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            var ry = layout.rowsTop
            for row in card.rows {
                let rr = NSRect(x: 10, y: ry, width: w - 20, height: layout.rowHeight - 4)
                NSColor(white: 1, alpha: 0.05).setFill()
                NSBezierPath(roundedRect: rr, xRadius: 9, yRadius: 9).fill()
                row.icon?.draw(in: NSRect(x: 16, y: ry + 4, width: 28, height: 28), from: .zero,
                               operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let t = NSMutableAttributedString(string: row.appName + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.white])
                if row.title != row.appName {
                    t.append(NSAttributedString(string: row.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.6)]))
                }
                t.draw(with: NSRect(x: 52, y: ry + 9, width: w - 70, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                ry += layout.rowHeight
            }
            if card.more > 0 {
                ("+\(card.more) more" as NSString).draw(in: NSRect(x: 18, y: ry + 10, width: w - 36, height: 20), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(white: 1, alpha: 0.5)])
            }
        }
    }
}
