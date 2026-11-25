
// Minimal check harness: Swift Testing in the Command Line Tools can't load tests built by
// this compiler, so these run as a plain executable: `swift run MonarchChecks`.
nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0
func expect(_ ok: @autoclosure () -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    checks += 1
    if !ok() { failures += 1; print("  ✕ \(file):\(line)") }
}
struct RequireFailed: Error {}
func require<T>(_ v: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
    checks += 1
    guard let v else { failures += 1; print("  ✕ \(file):\(line) (required value was nil)"); throw RequireFailed() }
    return v
}
func run(_ name: String, _ body: () throws -> Void) {
    let before = failures
    do { try body() } catch { failures += 1; print("  ✕ \(name) threw \(error)") }
    print(failures == before ? "✓ \(name)" : "✕ \(name)")
}
import CoreGraphics
import Foundation
import MonarchCore

// Your real arrangement: LG (2560×1440, primary) with the MacBook (1440×900) below it.
let lg = Display(id: 1, name: "LG", isBuiltin: false,
                 frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                 visibleFrame: CGRect(x: 0, y: 25, width: 2560, height: 1415))
let mac = Display(id: 2, name: "Built-in", isBuiltin: true,
                  frame: CGRect(x: 560, y: 1440, width: 1440, height: 900),
                  visibleFrame: CGRect(x: 560, y: 1465, width: 1440, height: 875))

struct GeometryTests {
    func cocoaToAXFlipsY() {
        // A 100pt-tall rect at the very top of a 1440pt-tall primary display.
        let r = Geometry.cocoaToAX(CGRect(x: 10, y: 1340, width: 50, height: 100), primaryHeight: 1440)
        expect(r == CGRect(x: 10, y: 0, width: 50, height: 100))
    }

    func unitRectsTileWithoutGaps() {
        let area = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let a = Geometry.rect(for: UnitRect(0, 0, 1.0 / 3, 1), in: area)
        let b = Geometry.rect(for: UnitRect(1.0 / 3, 0, 1.0 / 3, 1), in: area)
        let c = Geometry.rect(for: UnitRect(2.0 / 3, 0, 1.0 / 3, 1), in: area)
        expect(a.maxX == b.minX && b.maxX == c.minX && c.maxX == area.maxX)
        expect(a.minY == 25 && a.height == 1415)
    }

    func displayForWindowPicksLargestOverlap() {
        let w = CGRect(x: 600, y: 1300, width: 800, height: 600)   // mostly on the MacBook
        expect(Geometry.display(for: w, in: [lg, mac])?.id == 2)
        let off = CGRect(x: 5000, y: 5000, width: 10, height: 10)  // touches nothing: nearest
        expect(Geometry.display(for: off, in: [lg, mac]) != nil)
    }

    func stackedScreensFallBackToOther() {
        // MacBook sits below the LG, so there is nothing strictly "west": falls back to next.
        expect(Geometry.neighbor(of: lg, .west, in: [lg, mac])?.id == 2)
        expect(Geometry.neighbor(of: mac, .east, in: [lg, mac])?.id == 1)
        expect(Geometry.neighbor(of: lg, .next, in: [lg]) == nil)
    }

    func sideBySidePicksDirection() {
        let left = Display(id: 3, name: "L", isBuiltin: false, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
                           visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900))
        expect(Geometry.neighbor(of: lg, .west, in: [lg, mac, left])?.id == 3)
    }

    func mapKeepsRelativeFrameAndStaysInside() {
        let leftHalfLG = CGRect(x: 0, y: 25, width: 1280, height: 1415)
        let r = Geometry.map(leftHalfLG, from: lg.visibleFrame, to: mac.visibleFrame)
        expect(r == CGRect(x: 560, y: 1465, width: 720, height: 875))
        expect(mac.visibleFrame.contains(r))
    }

    func clampShrinksOversizedWindows() {
        let r = Geometry.clamp(CGRect(x: -50, y: 0, width: 3000, height: 200), into: mac.visibleFrame)
        expect(mac.visibleFrame.contains(r))
    }
}

struct HistoryTests {
    let f1 = CGRect(x: 0, y: 0, width: 100, height: 100)
    let f2 = CGRect(x: 50, y: 50, width: 200, height: 200)

    func undoSwapsSoSecondUndoRedoes() {
        let h = WindowHistory()
        h.remember(7, f1)
        expect(h.swapForUndo(7, current: f2) == f1)
        expect(h.swapForUndo(7, current: f1) == f2)
        expect(h.swapForUndo(8, current: f1) == nil)
    }

    func cycleAdvancesOnlyWithinWindowForSameKeyAndWindow() {
        let h = WindowHistory()
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, current: f1, now: 10) == 0)
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, current: f2, now: 10.5) == 1)
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, current: f2, now: 11) == 2)
        expect(h.nextCycleIndex(key: "left", window: 1, count: 3, current: f2, now: 11.2) == 0)   // wraps
        expect(h.nextCycleIndex(key: "right", window: 1, count: 3, current: f2, now: 11.3) == 0)  // other key
        expect(h.nextCycleIndex(key: "right", window: 1, count: 3, current: f2, now: 13.0) == 0)  // too late
        // Undo after a cycle returns to the frame before the cycle started, not a mid-cycle one.
        expect(h.swapForUndo(1, current: f1) == f2)
    }

    func fillToggleRoundTrip() {
        let h = WindowHistory()
        h.saveBeforeFill(3, f1)
        expect(h.peekBeforeFill(3) == f1)
        expect(h.takeBeforeFill(3) == f1)
        expect(h.takeBeforeFill(3) == nil)
    }
}

struct ShortcutTests {
    func parsesModifiersAndKeys() throws {
        let s = try require(Shortcut("ctrl+alt+cmd+left"))
        expect(s.keyCode == 123)
        expect(s.modifiers == Shortcut.control | Shortcut.option | Shortcut.cmd)
        expect(s.description == "⌃⌥⌘ ←")
        expect(Shortcut("ctrl+alt+delete")?.keyCode == 51)
        expect(Shortcut("ctrl+cmd+f")?.keyCode == 3)
    }

    func rejectsBadInput() {
        expect(Shortcut("ctrl+alt") == nil)
        expect(Shortcut("ctrl+a+b") == nil)
        expect(Shortcut("ctrl+nosuchkey") == nil)
    }

    func everyDefaultParsesAndIsUnique() {
        let parsed = Action.allCases.compactMap { Shortcut($0.defaultShortcut) }
        expect(parsed.count == Action.allCases.count)
        expect(Set(parsed).count == parsed.count)
    }
}

struct ConfigurationTests {
    func partialFileKeepsOtherDefaults() throws {
        let json = #"{"bindings": {"snap.left": "ctrl+cmd+left", "snap.center": ""}}"#
        let c = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        let (b, errors) = c.resolvedBindings()
        expect(errors.isEmpty)
        expect(b.first { $0.0 == .snapLeft }?.1 == Shortcut("ctrl+cmd+left"))
        expect(!b.contains { $0.0 == .center })                    // "" disables
        expect(b.count == Action.allCases.count - 1)
        expect(c.axTimeout == 0.25 && c.snappingEnabled)
    }

    func reportsBadEntries() throws {
        let json = #"{"bindings": {"snap.left": "ctrl+zz", "nope": "ctrl+a"}}"#
        let c = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        expect(c.resolvedBindings().errors.count == 2)
    }
}

struct PerfStatsTests {
    func summaryAndRingWrap() throws {
        let p = PerfStats()
        for i in 1...300 { p.record("x", ms: Double(i)) }
        let s = try require(p.summary("x"))
        expect(s.count == PerfStats.capacity)
        expect(s.last == 300 && s.max == 300)
        expect(s.median > 150 && s.p95 > s.median)
        expect(p.summary("missing") == nil)
    }
}

struct FocusTests {
    func cand(_ id: UInt32, _ f: CGRect, pid: Int32 = 1, min: Bool = false, hidden: Bool = false) -> FocusCandidate {
        FocusCandidate(id: id, pid: pid, frame: f, isMinimized: min, appHidden: hidden)
    }
    let onLG = CGRect(x: 100, y: 100, width: 800, height: 600)
    let onLG2 = CGRect(x: 1200, y: 100, width: 800, height: 600)
    let onMac = CGRect(x: 600, y: 1500, width: 700, height: 500)
    // Hammerspoon parks hidden-workspace windows past the MacBook's bottom-right corner.
    let parked = CGRect(x: 1999, y: 2310, width: 700, height: 500)

    func testUsableExcludesParkedMinimizedHidden() {
        expect(FocusLogic.isUsable(cand(1, onMac), on: mac, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, parked), on: mac, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, onMac, min: true), on: mac, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, onMac, hidden: true), on: mac, in: [lg, mac]))
        expect(!FocusLogic.isUsable(cand(1, onLG), on: mac, in: [lg, mac]))
    }

    func testAlreadyFocusedThereDoesNothing() {
        let w: [UInt32: FocusCandidate] = [1: cand(1, onMac), 2: cand(2, onLG)]
        var h = FocusHistory(); h.record(window: 2, display: 1)
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 1, windows: w, history: h, zOrder: { [] }) == nil)
    }

    func testPrefersLastUsedThenMRUThenTopmost() {
        // Two iTerms (same pid), one per screen, plus Slack on the MacBook used last there.
        let w: [UInt32: FocusCandidate] = [1: cand(1, onLG, pid: 10), 2: cand(2, onMac, pid: 10), 3: cand(3, onMac, pid: 20)]
        var h = FocusHistory()
        h.record(window: 2, display: 2)
        h.record(window: 3, display: 2)          // Slack was the last used on the MacBook
        h.record(window: 1, display: 1)          // now working in iTerm on the LG
        var zCalled = false
        let pick = FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 1, windows: w, history: h,
                                              zOrder: { zCalled = true; return [] })
        expect(pick == 3)                        // Slack, not the other iTerm
        expect(!zCalled)                         // no WindowServer query needed

        // Last-used window was parked (workspace switched): falls back to MRU on that screen.
        var w2 = w; w2[3] = cand(3, parked, pid: 20)
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 1, windows: w2, history: h, zOrder: { [] }) == 2)

        // No history at all: top-most usable window from z-order.
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: 1, windows: w, history: FocusHistory(),
                                          zOrder: { [1, 3, 2] }) == 3)
    }

    func testHistoryForgetAndLimit() {
        var h = FocusHistory()
        for i in 1...70 { h.record(window: UInt32(i), display: 1) }
        expect(h.mru.count == FocusHistory.mruLimit && h.mru.first == 70)
        h.forget(window: 70)
        expect(h.lastByDisplay[1] == nil && h.mru.first == 69)
        h.record(window: 5, display: 2)
        h.keepDisplays([1])
        expect(h.lastByDisplay[2] == nil)
    }

    func testDirectionPicksStraightAheadOverSideways() {
        let from = CGRect(x: 1000, y: 500, width: 200, height: 200)
        let ahead = cand(1, CGRect(x: 400, y: 500, width: 200, height: 200))     // far, straight west
        let side = cand(2, CGRect(x: 750, y: 150, width: 200, height: 200))      // close, up-left
        let behind = cand(3, CGRect(x: 1500, y: 500, width: 200, height: 200))
        expect(FocusLogic.window(in: .west, from: from, candidates: [ahead, side, behind]) == 1)
        expect(FocusLogic.window(in: .east, from: from, candidates: [ahead, side, behind]) == 3)
        expect(FocusLogic.window(in: .south, from: from, candidates: [ahead, side, behind]) == nil)
    }
}

struct ArrangeTests {
    func testColumnCounts() {
        expect(ArrangeLayout.columnCounts(0) == [])
        expect(ArrangeLayout.columnCounts(1) == [1])
        expect(ArrangeLayout.columnCounts(2) == [1, 1])
        expect(ArrangeLayout.columnCounts(3) == [1, 2])      // big left + 2 stacked
        expect(ArrangeLayout.columnCounts(4) == [2, 2])
        expect(ArrangeLayout.columnCounts(5) == [1, 2, 2])
        expect(ArrangeLayout.columnCounts(7) == [2, 2, 3])
        expect(ArrangeLayout.columnCounts(9) == [3, 3, 3])
        expect(ArrangeLayout.columnCounts(12).reduce(0, +) == 12)
    }

    func testFramesTileExactly() {
        let area = lg.visibleFrame
        for n in 1...12 {
            let f = ArrangeLayout.frames(count: n, in: area)
            expect(f.count == n)
            let total = f.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            expect(abs(total - area.width * area.height) < 1)                 // no gaps
            for i in 0..<f.count { for j in (i + 1)..<f.count { expect(f[i].intersection(f[j]).isEmpty || f[i].intersection(f[j]).width * f[i].intersection(f[j]).height == 0) } }
            expect(f.allSatisfy { area.contains($0) })
        }
        // Front-most window gets the biggest slot.
        let three = ArrangeLayout.frames(count: 3, in: area)
        expect(three[0].height == area.height && three[1].height < area.height)
    }
}

struct SwitcherTests {
    func testOrderFocusedThenMRUThenZThenOthers() {
        let ids = SwitcherLogic.order(focused: 5, mru: [5, 3, 9], zOrder: [1, 3, 7], others: [8, 7, 2], include: { $0 != 9 })
        expect(ids == [5, 3, 1, 7, 8, 2])
        let many = SwitcherLogic.order(focused: nil, mru: Array(1...30), zOrder: [], others: [], include: { _ in true })
        expect(many.count == SwitcherLogic.maxItems)
    }

    func testQuickTapTogglesLastTwo() {
        expect(SwitcherLogic.initialIndex(count: 4, focusedFirst: true, step: 1) == 1)
        expect(SwitcherLogic.initialIndex(count: 4, focusedFirst: true, step: -1) == 3)
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: true, step: 1) == nil)   // nothing else
        expect(SwitcherLogic.initialIndex(count: 1, focusedFirst: false, step: 1) == 0)    // ⌘` other screen
        expect(SwitcherLogic.initialIndex(count: 0, focusedFirst: false, step: 1) == nil)
        expect(SwitcherLogic.move(3, by: 1, count: 4) == 0 && SwitcherLogic.move(0, by: -1, count: 4) == 3)
    }

    func testWorkspaceSnapshotParsesHammerspoonState() {
        let plist: [String: Any] = [
            "active": ["LG-UUID": NSNumber(value: 1), "MAC-UUID": NSNumber(value: 3)],
            "hidden": ["6140": ["ws": NSNumber(value: 1), "scr": "MAC-UUID", "x": NSNumber(value: 10),
                                "y": NSNumber(value: 20), "w": NSNumber(value: 800), "h": NSNumber(value: 600),
                                "z": NSNumber(value: 2), "px": NSNumber(value: 1999), "py": NSNumber(value: 2310)],
                       "junk": ["ws": NSNumber(value: 2)]],
        ]
        let w = WorkspaceState(hammerspoon: plist)
        expect(w.active["MAC-UUID"] == 3)
        expect(w.hidden.count == 1 && w.parked(6140)?.ws == 1 && w.parked(6140)?.relativeFrame == CGRect(x: 10, y: 20, width: 800, height: 600))
        expect(w.parked(6140)?.px == 1999 && w.parked(6140)?.z == 2)
        expect(w.workspace(of: 6140, displayUUID: "").number == 1 && !w.workspace(of: 6140, displayUUID: "").shown)
        expect(w.workspace(of: 42, displayUUID: "MAC-UUID") == (3, true))
        expect(w.workspace(of: 42, displayUUID: "UNKNOWN") == (1, true))
        expect(WorkspaceState(hammerspoon: [:]).hidden.isEmpty)
    }
}

struct WorkspaceTests {
    func entry(_ ws: Int, _ scr: String, z: Int) -> ParkedWindow {
        ParkedWindow(ws: ws, scr: scr, x: 0, y: 0, w: 100, h: 100, z: z, px: 5000, py: 5000)
    }

    func testUsedIncomingAndMenu() {
        var s = WorkspaceState()
        s.active = ["LG": 1, "MAC": 2]
        s.hidden = ["10": entry(3, "LG", z: 1), "11": entry(3, "LG", z: 2), "12": entry(1, "MAC", z: 1)]
        expect(s.used(on: "LG") == [1, 3] && s.used(on: "MAC") == [1, 2])
        expect(s.incoming(3, on: "LG").map(\.id) == [11, 10])          // bottom-most first, top last
        expect(s.incoming(5, on: "LG").isEmpty)
        expect(s.menuTitle(displayOrder: ["LG", "MAC"]) == "[1] 3  │  1 [2]")
        expect(s.activeWorkspace("NEW") == 1)
    }

    func testStateRoundTripsAsJSON() throws {
        var s = WorkspaceState()
        s.active = ["LG": 4]
        s.hidden = ["10": entry(3, "LG", z: 1)]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: data)
        expect(back == s)
    }

    func testParkingSpotsAndOverlap() {
        let spots = Parking.spots(for: CGSize(width: 800, height: 600), screen: lg.frame)
        expect(spots[0] == CGPoint(x: 2559, y: 1439))
        expect(spots[1] == CGPoint(x: -799, y: 1439))
        // LG bottom-right lands right of the MacBook (which spans x 560–2000): no peeking.
        expect(!Parking.overlapsOther(CGRect(origin: spots[0], size: CGSize(width: 800, height: 600)), home: lg.id, displays: [lg, mac]))
        // A window parked at the LG's bottom edge above the MacBook would peek onto it.
        expect(Parking.overlapsOther(CGRect(x: 1000, y: 1439, width: 800, height: 600), home: lg.id, displays: [lg, mac]))
    }

    func testAtParkAndFit() {
        let e = entry(2, "LG", z: 1)
        expect(Parking.isAtPark(CGRect(x: 5003, y: 4998, width: 100, height: 100), e))
        expect(!Parking.isAtPark(CGRect(x: 100, y: 100, width: 100, height: 100), e))
        var inFlight = e; inFlight.px = nil
        expect(Parking.isAtPark(CGRect(x: 100, y: 100, width: 100, height: 100), inFlight))
        let f = Parking.fit(CGRect(x: 2000, y: 100, width: 2000, height: 500), into: CGSize(width: 1440, height: 875))
        expect(f == CGRect(x: 0, y: 100, width: 1440, height: 500))
    }

    func testActionNumbers() {
        expect(Action.workspace3.switchWorkspace == 3 && Action.workspace3.moveWorkspace == nil)
        expect(Action.moveToWorkspace7.moveWorkspace == 7 && Action.moveToWorkspace7.switchWorkspace == nil)
        expect(Action.restoreAllWindows.switchWorkspace == nil && Action.restoreAllWindows.isWorkspaceAction)
        expect(Shortcut(Action.moveToWorkspace7.defaultShortcut) == Shortcut("alt+shift+7"))
    }
}

struct OverviewTests {
    func testCardsActivePlusAndOrder() {
        let cards = OverviewModel.cards(active: 2, visible: [10, 11], parked: [(20, 1, 2), (21, 1, 1), (30, 4, 1)])
        expect(cards.map(\.workspace) == [1, 2, 4, 3])                 // 1, 2, 4, then "+" = first free (3)
        expect(cards[0].windows == [21, 20])                            // parked: top-most (lowest z) first
        expect(cards[1].isActive && cards[1].windows == [10, 11])
        expect(cards.last!.isPlus && cards.last!.windows.isEmpty)
        // An empty active workspace still gets a card.
        let empty = OverviewModel.cards(active: 5, visible: [], parked: [])
        expect(empty.map(\.workspace) == [5, 1] && empty[0].isActive && empty[1].isPlus)
        // All nine used: no "+" card.
        let full = OverviewModel.cards(active: 1, visible: [1], parked: (2...9).map { (UInt32($0), $0, 1) })
        expect(full.count == 9 && !full.contains { $0.isPlus })
    }

    func testLayoutColumnsAndFit() {
        let wide = OverviewModel.layout(cardCount: 5, size: CGSize(width: 2560, height: 1440))
        expect(wide.cols == 4 && wide.cardFrames.count == 5)
        expect(wide.cardFrames.allSatisfy { $0.height <= 460 && $0.minX >= 44 && $0.maxX <= 2560 - 44 + 0.5 })
        let small = OverviewModel.layout(cardCount: 5, size: CGSize(width: 1440, height: 900))
        expect(small.cols == 3 && small.cardFrames[3].minY > small.cardFrames[0].maxY)
        expect(small.maxRows >= 1)
        expect(OverviewModel.layout(cardCount: 2, size: CGSize(width: 2560, height: 1440)).cols == 2)
    }

    func testSelectionMoves() {
        typealias S = OverviewModel.Selection
        let cards = [5, 2], rows = [[0, 3, 1, 0, 0], [2, 0]], cols = [3, 2]
        // → past the last card continues onto the next screen.
        expect(OverviewModel.move(S(screen: 0, card: 4, row: 0), dx: 1, dy: 0, cards: cards, rows: rows, cols: cols) == S(screen: 1, card: 0, row: 0))
        expect(OverviewModel.move(S(screen: 1, card: 0, row: 0), dx: -1, dy: 0, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 4, row: 0))
        // ↓ through rows, then to the card below.
        expect(OverviewModel.move(S(screen: 0, card: 1, row: 0), dx: 0, dy: 1, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 1, row: 1))
        expect(OverviewModel.move(S(screen: 0, card: 1, row: 3), dx: 0, dy: 1, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 4, row: 0))
        // ↑ from a card's top goes to the card above, onto its last row.
        expect(OverviewModel.move(S(screen: 0, card: 4, row: 0), dx: 0, dy: -1, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 1, row: 3))
        // Row clamps when moving sideways onto a card with fewer rows.
        expect(OverviewModel.move(S(screen: 0, card: 1, row: 3), dx: 1, dy: 0, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 2, row: 1))
        // Edges stay put.
        expect(OverviewModel.move(S(screen: 0, card: 0, row: 0), dx: -1, dy: 0, cards: cards, rows: rows, cols: cols) == S(screen: 0, card: 0, row: 0))
    }

    func testBridgeParsing() {
        // (exercised through Action defaults here; the app parses the same command words)
        expect(Shortcut(Action.toggleOverview.defaultShortcut) == Shortcut("ctrl+alt+space"))
    }
}

struct GestureTests {
    typealias Frame = [(Int32, Float, Float)]
    /// Feeds frames 10 ms apart; returns every non-empty output.
    func run(_ r: inout GestureRecognizer, _ frames: [Frame], start: Double = 0, step: Double = 0.01) -> [GestureOutput] {
        var out: [GestureOutput] = []
        for (i, f) in frames.enumerated() {
            let pts = f.map { TouchPoint(id: $0.0, x: $0.1, y: $0.2) }
            let o = pts.withUnsafeBufferPointer { r.process($0, time: start + Double(i) * step) }
            if !o.isEmpty { out.append(o) }
        }
        return out
    }
    func three(_ dx: Float, _ dy: Float, ids: [Int32] = [1, 2, 3]) -> Frame {
        ids.enumerated().map { ($0.element, 0.3 + Float($0.offset) * 0.1 + dx, 0.5 + dy) }
    }
    func four(_ dx: Float, _ dy: Float = 0) -> Frame { (1...4).map { (Int32($0), 0.2 + Float($0) * 0.1 + dx, 0.5 + dy) } }
    func count(_ o: [GestureOutput], _ k: KeyPath<GestureOutput, SwipeSample?>) -> Int { o.filter { $0[keyPath: k] != nil }.count }

    func testSwipeUpLocksCrossesEndsOnce() {
        var r = GestureRecognizer(config: GestureConfig())                  // 3f threshold 0.07
        let o = run(&r, [three(0, 0), three(0, 0.03), three(0, 0.08), three(0, 0.2), three(0, 0.25), []])
        expect(o.filter(\.began).count == 1 && o.filter(\.lifted).count == 1)
        expect(count(o, \.locked) == 1 && count(o, \.crossed) == 1 && count(o, \.ended) == 1)
        let e = o.compactMap(\.ended).first
        expect(e?.fingers == 3 && e?.direction == .up && (e?.distance ?? 0) >= 0.2)
        expect((e?.velocity ?? 0) > 1)                                        // moving fast at release
        expect(o.last?.lifted == true && o.last?.ended != nil)                // ended and lifted together
    }

    func testDirectionLockSurvivesWobbleAndReversal() {
        var r = GestureRecognizer(config: GestureConfig())
        // Locks vertical, then drifts sideways a lot: still a vertical gesture.
        let o = run(&r, [three(0, 0), three(0, 0.03), three(0.15, 0.04), three(0.3, 0.05), []])
        expect(o.compactMap(\.locked).first?.axis == .vertical)
        expect(o.compactMap(\.ended).first?.axis == .vertical)
        // Reversing after the lock keeps the axis; displacement can go negative.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = run(&r2, [three(0, 0), three(0, 0.03), three(0, -0.1), []])
        expect(o2.compactMap(\.ended).first?.direction == .down)
    }

    func testFourFingerHorizontalAndDiagonalRejected() {
        var r = GestureRecognizer(config: GestureConfig())
        let o = run(&r, [four(0), four(-0.05), four(-0.11), []])
        let c = o.compactMap(\.crossed).first
        expect(c?.fingers == 4 && c?.direction == .left)
        // 45° diagonal: never locks, even with ratio 1 in the config.
        var cfg = GestureConfig(); cfg.ratio = 1
        var r2 = GestureRecognizer(config: cfg)
        let o2 = run(&r2, [three(0, 0), three(0.1, 0.1), three(0.2, 0.2), []])
        expect(count(o2, \.locked) == 0 && o2.count == 2)                    // began, lifted
    }

    func testPartialLiftsAndFingerChanges() {
        var r = GestureRecognizer(config: GestureConfig())
        // Two-finger scroll: nothing at all.
        expect(run(&r, [[(1, 0.4, 0.5), (2, 0.5, 0.5)], [(1, 0.4, 0.9), (2, 0.5, 0.9)], []]).isEmpty)
        // A third finger landing late restarts measuring from where it landed.
        let o = run(&r, [[(1, 0.4, 0.5), (2, 0.5, 0.5)], three(0, 0.05), three(0, 0.09), three(0, 0.2), []])
        expect((o.compactMap(\.ended).first?.distance ?? 0) < 0.16)
        // After the lock, one finger lifting early doesn't change the gesture or end it.
        var r2 = GestureRecognizer(config: GestureConfig())
        let o2 = run(&r2, [three(0, 0), three(0, 0.03), three(0, 0.1), [(1, 0.3, 0.6), (2, 0.4, 0.6)], [(1, 0.3, 0.65)], []])
        expect(count(o2, \.ended) == 1 && o2.compactMap(\.ended).first?.fingers == 3)
        // Before the lock, a 4th finger turns a 3-finger start into a 4-finger gesture.
        var r3 = GestureRecognizer(config: GestureConfig())
        let o3 = run(&r3, [three(0, 0), four(0), four(-0.05), four(-0.12), []])
        expect(o3.compactMap(\.locked).first?.fingers == 4)
    }

    func testFiveFingersCancelAndResetRecovers() {
        var r = GestureRecognizer(config: GestureConfig())
        let five: Frame = (1...5).map { (Int32($0), 0.1 + Float($0) * 0.1, 0.5) }
        let o = run(&r, [five, five.map { ($0.0, $0.1, $0.2 + 0.2) }, []])
        expect(count(o, \.locked) == 0 && o.filter(\.lifted).count == 1)
        // reset() mid-gesture reports lifted once, then the next gesture works normally.
        var r2 = GestureRecognizer(config: GestureConfig())
        _ = run(&r2, [three(0, 0), three(0, 0.05)])
        expect(r2.reset().lifted)
        expect(!r2.reset().lifted)
        let o2 = run(&r2, [three(0, 0), three(0, 0.03), three(0, 0.1), []], start: 5)
        expect(count(o2, \.ended) == 1)
    }

    func testRepeatedGesturesEachActOnce() {
        var r = GestureRecognizer(config: GestureConfig())
        var crossed = 0, ended = 0
        for k in 0..<5 {
            let o = run(&r, [four(0), four(-0.05), four(-0.12), four(-0.2), []], start: Double(k))
            crossed += count(o, \.crossed); ended += count(o, \.ended)
        }
        expect(crossed == 5 && ended == 5)
    }

    func testSlowSwipeHasLowVelocity() {
        var r = GestureRecognizer(config: GestureConfig())
        let frames = (0...40).map { three(0, Float($0) * 0.004) } + [three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), three(0, 0.16), []]
        let e = run(&r, frames).compactMap(\.ended).first
        expect(e != nil && abs(e!.velocity) < 0.2)                           // held still before lifting
    }

    func testInteractiveDecision() {
        expect(InteractiveDecision.complete(progress: 0.6, velocity: 0))
        expect(!InteractiveDecision.complete(progress: 0.4, velocity: 0))
        expect(InteractiveDecision.complete(progress: 0.2, velocity: 3))      // flick
        expect(!InteractiveDecision.complete(progress: 0.8, velocity: -3))    // flick back
    }

    func testConfigDecodingAndHammerspoonImport() throws {
        let cfg: [String: Any] = ["algo": "net", "guard": "0.05", "ratio": 1, "sw3": "0.02", "sw4": "0.03", "trigger": "lift"]
        let g = GestureConfig(hammerspoon: cfg)
        expect(g.trigger == .lift && g.ratio == 1)
        expect(g.threeFinger == 0.07 && g.fourFinger == 0.10 && g.clickGuard == 0.35)
        // An older config.json without the new keys keeps its values and gets defaults for the rest.
        let old = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"threeFinger":0.02,"trigger":"lift"}"#.utf8))
        expect(old.threeFinger == 0.02 && old.trigger == .lift && old.lockDistance == 0.012 && old.overviewTravel == 0.18)
    }
}


struct Step9Tests {
    func testHelpSheetUsesLiveBindingsAndBalancesColumns() {
        var b: [Action: Shortcut] = [:]
        for (a, s) in AppConfiguration().resolvedBindings().bindings { b[a] = s }
        let all = HelpSheet.sections(bindings: b, states: .init(cross: true, hover: false), gestures: true)
        let rows = all.flatMap(\.rows)
        expect(rows.contains { $0.keys == "⌥ 1…9" })
        expect(rows.contains { $0.keys == "⌥⇧ 1…9" })
        expect(rows.contains { $0.keys == "⌃⌥⌘ 1…9" })
        expect(rows.contains { $0.text.hasSuffix("[ON]") } && rows.contains { $0.text.hasSuffix("[OFF]") })
        expect(rows.contains { $0.keys == "⌃⌥ /" } && !rows.contains { $0.keys == "⌃⌥ 1" })
        // A disabled action disappears; without gestures the gesture rows go.
        b[.showHelp] = nil
        let fewer = HelpSheet.sections(bindings: b, states: .init(cross: true, hover: true), gestures: false).flatMap(\.rows)
        expect(!fewer.contains { $0.keys == "⌃⌥ /" } && !fewer.contains { $0.keys.contains("fingers") })
        // Columns: every section once, heights within one section of each other.
        let (l, r) = HelpSheet.columns(all)
        expect(l + r == all && !l.isEmpty && !r.isEmpty)
        let h = { (x: [HelpSheet.Section]) in x.reduce(0) { $0 + $1.rows.count + 2 } }
        expect(abs(h(l) - h(r)) <= all.map { $0.rows.count + 2 }.max()!)
    }

    func testHelpShortcutParses() {
        expect(Shortcut(Action.showHelp.defaultShortcut)?.keyCode == 44)
        expect(Action(rawValue: "layout.coding") == nil)
    }
}

// MARK: run
run("GeometryTests.cocoaToAXFlipsY") { GeometryTests().cocoaToAXFlipsY() }
run("GeometryTests.unitRectsTileWithoutGaps") { GeometryTests().unitRectsTileWithoutGaps() }
run("GeometryTests.displayForWindowPicksLargestOverlap") { GeometryTests().displayForWindowPicksLargestOverlap() }
run("GeometryTests.stackedScreensFallBackToOther") { GeometryTests().stackedScreensFallBackToOther() }
run("GeometryTests.sideBySidePicksDirection") { GeometryTests().sideBySidePicksDirection() }
run("GeometryTests.mapKeepsRelativeFrameAndStaysInside") { GeometryTests().mapKeepsRelativeFrameAndStaysInside() }
run("GeometryTests.clampShrinksOversizedWindows") { GeometryTests().clampShrinksOversizedWindows() }
run("HistoryTests.undoSwapsSoSecondUndoRedoes") { HistoryTests().undoSwapsSoSecondUndoRedoes() }
run("HistoryTests.cycleAdvancesOnlyWithinWindowForSameKeyAndWindow") { HistoryTests().cycleAdvancesOnlyWithinWindowForSameKeyAndWindow() }
run("HistoryTests.fillToggleRoundTrip") { HistoryTests().fillToggleRoundTrip() }
run("ShortcutTests.parsesModifiersAndKeys") { try ShortcutTests().parsesModifiersAndKeys() }
run("ShortcutTests.rejectsBadInput") { ShortcutTests().rejectsBadInput() }
run("ShortcutTests.everyDefaultParsesAndIsUnique") { ShortcutTests().everyDefaultParsesAndIsUnique() }
run("ConfigurationTests.partialFileKeepsOtherDefaults") { try ConfigurationTests().partialFileKeepsOtherDefaults() }
run("ConfigurationTests.reportsBadEntries") { try ConfigurationTests().reportsBadEntries() }
run("PerfStatsTests.summaryAndRingWrap") { try PerfStatsTests().summaryAndRingWrap() }
run("FocusTests.testUsableExcludesParkedMinimizedHidden") { FocusTests().testUsableExcludesParkedMinimizedHidden() }
run("FocusTests.testAlreadyFocusedThereDoesNothing") { FocusTests().testAlreadyFocusedThereDoesNothing() }
run("FocusTests.testPrefersLastUsedThenMRUThenTopmost") { FocusTests().testPrefersLastUsedThenMRUThenTopmost() }
run("FocusTests.testHistoryForgetAndLimit") { FocusTests().testHistoryForgetAndLimit() }
run("FocusTests.testDirectionPicksStraightAheadOverSideways") { FocusTests().testDirectionPicksStraightAheadOverSideways() }
run("ArrangeTests.testColumnCounts") { ArrangeTests().testColumnCounts() }
run("ArrangeTests.testFramesTileExactly") { ArrangeTests().testFramesTileExactly() }
run("SwitcherTests.testOrderFocusedThenMRUThenZThenOthers") { SwitcherTests().testOrderFocusedThenMRUThenZThenOthers() }
run("SwitcherTests.testQuickTapTogglesLastTwo") { SwitcherTests().testQuickTapTogglesLastTwo() }
run("SwitcherTests.testWorkspaceSnapshotParsesHammerspoonState") { SwitcherTests().testWorkspaceSnapshotParsesHammerspoonState() }
run("WorkspaceTests.testUsedIncomingAndMenu") { WorkspaceTests().testUsedIncomingAndMenu() }
run("WorkspaceTests.testStateRoundTripsAsJSON") { try WorkspaceTests().testStateRoundTripsAsJSON() }
run("WorkspaceTests.testParkingSpotsAndOverlap") { WorkspaceTests().testParkingSpotsAndOverlap() }
run("WorkspaceTests.testAtParkAndFit") { WorkspaceTests().testAtParkAndFit() }
run("WorkspaceTests.testActionNumbers") { WorkspaceTests().testActionNumbers() }
run("OverviewTests.testCardsActivePlusAndOrder") { OverviewTests().testCardsActivePlusAndOrder() }
run("OverviewTests.testLayoutColumnsAndFit") { OverviewTests().testLayoutColumnsAndFit() }
run("OverviewTests.testSelectionMoves") { OverviewTests().testSelectionMoves() }
run("OverviewTests.testBridgeParsing") { OverviewTests().testBridgeParsing() }
run("GestureTests.testSwipeUpLocksCrossesEndsOnce") { GestureTests().testSwipeUpLocksCrossesEndsOnce() }
run("GestureTests.testDirectionLockSurvivesWobbleAndReversal") { GestureTests().testDirectionLockSurvivesWobbleAndReversal() }
run("GestureTests.testFourFingerHorizontalAndDiagonalRejected") { GestureTests().testFourFingerHorizontalAndDiagonalRejected() }
run("GestureTests.testPartialLiftsAndFingerChanges") { GestureTests().testPartialLiftsAndFingerChanges() }
run("GestureTests.testFiveFingersCancelAndResetRecovers") { GestureTests().testFiveFingersCancelAndResetRecovers() }
run("GestureTests.testRepeatedGesturesEachActOnce") { GestureTests().testRepeatedGesturesEachActOnce() }
run("GestureTests.testSlowSwipeHasLowVelocity") { GestureTests().testSlowSwipeHasLowVelocity() }
run("GestureTests.testInteractiveDecision") { GestureTests().testInteractiveDecision() }
run("GestureTests.testConfigDecodingAndHammerspoonImport") { try GestureTests().testConfigDecodingAndHammerspoonImport() }
run("Step9Tests.testHelpSheetUsesLiveBindingsAndBalancesColumns") { Step9Tests().testHelpSheetUsesLiveBindingsAndBalancesColumns() }
run("Step9Tests.testHelpShortcutParses") { Step9Tests().testHelpShortcutParses() }
print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
