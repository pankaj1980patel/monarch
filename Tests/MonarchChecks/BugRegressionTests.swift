import CoreGraphics
import Foundation
import MonarchCore

// One test per bug that reached a build. Each replays the situation that went wrong, so a
// future change that brings the bug back fails here first.

// MARK: - ⌘Tab across workspaces (2026-11-25)

/// ⌘Tab to a window on another workspace, quick tap back, ⌘Tab to a third window, quick tap:
/// the last tap must return to the window used just before, not to the one from another
/// workspace. It went to Chrome because a picked window was skipped while still parked.
struct SwitcherAcrossWorkspacesTests {
    let display = Display(id: 1, name: "Built-in", isBuiltin: true,
                          frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                          visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775), uuid: "D1")
    let onScreen = CGRect(x: 0, y: 25, width: 1280, height: 775)
    let parked = CGRect(x: 1279, y: 759, width: 1280, height: 800)    // a real parked frame

    /// Window ids: 1 = VS Code (workspace 2), 2 = Pastora (workspace 2), 3 = Chrome (workspace 1).
    struct World {
        var frames: [UInt32: CGRect]
        var history = FocusHistory()
        var focused: UInt32
    }

    /// What AutoFocusManager.record does for a focus change.
    func record(_ id: UInt32, picked: Bool, in w: inout World) {
        guard let d = FocusLogic.mruDisplay(frame: w.frames[id]!, displays: [display], picked: picked,
                                            parkedHome: picked ? display.id : nil) else { return }
        w.history.record(window: id, display: d)
    }

    /// One ⌘Tab: Tab pressed `step` times while ⌘ is held (1 = quick tap). Returns the pick.
    func commandTab(_ step: Int, in w: inout World) -> UInt32 {
        let ids = SwitcherLogic.order(focused: w.focused, mru: w.history.mru, zOrder: [1, 2, 3],
                                      others: [1, 2, 3], include: { _ in true })
        let first = SwitcherLogic.initialIndex(count: ids.count, focusedFirst: ids.first == w.focused, step: 1)!
        let picked = ids[(first + step - 1) % ids.count]
        record(picked, picked: true, in: &w)                       // noteFocusing: before the reveal
        // macOS confirms the focus while Monarch still has the old (parked) frame: the window's
        // move back hasn't been read yet. It's the window being picked (pending focus).
        record(picked, picked: true, in: &w)
        // Then the restore is read back: it's on screen, the other workspace's windows parked.
        if w.frames[picked] == parked {
            let ws2: Set<UInt32> = [1, 2]
            for id in w.frames.keys { w.frames[id] = (ws2.contains(id) == ws2.contains(picked)) ? onScreen : parked }
        }
        w.focused = picked
        return picked
    }

    func testQuickTapReturnsToPreviousWindowAfterCrossWorkspacePicks() {
        var w = World(frames: [1: onScreen, 2: onScreen, 3: parked], focused: 1)
        record(2, picked: false, in: &w)
        record(1, picked: false, in: &w)                           // recent: VS Code, Pastora
        expect(commandTab(2, in: &w) == 3)                         // ⌘Tab×2 → Chrome (workspace 1)
        expect(commandTab(1, in: &w) == 1)                         // quick tap → back to VS Code
        expect(commandTab(2, in: &w) == 2)                         // ⌘Tab×2 → Pastora
        expect(commandTab(1, in: &w) == 1)                         // the bug: this went to Chrome
        expect(commandTab(1, in: &w) == 2)                         // and toggles back
    }

    func testTogglingBetweenTwoWindowsOnDifferentWorkspaces() {
        var w = World(frames: [1: onScreen, 2: onScreen, 3: parked], focused: 1)
        record(1, picked: false, in: &w)
        expect(commandTab(2, in: &w) == 3)                         // VS Code → Chrome
        for i in 0..<6 { expect(commandTab(1, in: &w) == (i % 2 == 0 ? 1 : 3)) }
    }

    func testParkedWindowsFocusedInPassingAreNotRecent() {
        // During a workspace switch macOS focuses parked windows in passing: they must stay out.
        expect(FocusLogic.mruDisplay(frame: parked, displays: [display], picked: false, parkedHome: 1) == nil)
        expect(FocusLogic.mruDisplay(frame: parked, displays: [display], picked: true, parkedHome: 1) == 1)
        expect(FocusLogic.mruDisplay(frame: onScreen, displays: [display], picked: false, parkedHome: nil) == 1)
        // A parked window whose display is gone, or with no known home, isn't recorded.
        expect(FocusLogic.mruDisplay(frame: parked, displays: [display], picked: true, parkedHome: 9) == nil)
        expect(FocusLogic.mruDisplay(frame: parked, displays: [display], picked: true, parkedHome: nil) == nil)
        // Visible wins over the parked home (a window already restored).
        let other = Display(id: 2, name: "Ext", isBuiltin: false, frame: CGRect(x: 1280, y: 0, width: 1920, height: 1080),
                            visibleFrame: CGRect(x: 1280, y: 25, width: 1920, height: 1055), uuid: "D2")
        let onOther = CGRect(x: 1400, y: 100, width: 800, height: 600)
        expect(FocusLogic.mruDisplay(frame: onOther, displays: [display, other], picked: true, parkedHome: 1) == 2)
    }
}

// MARK: - New windows missing from ⌘Tab and the overview (2026-11-25)

struct WindowAnnouncementTests {
    /// First read timed out: tracked, not announced. The next successful read must announce it.
    func testFailedFirstReadIsAnnouncedLater() {
        var a = WindowAnnouncements()
        expect(a.needsAnnouncing(7))                               // tracked, first read failed
        a.announced(7)                                             // e.g. the focus handler read it
        expect(!a.needsAnnouncing(7))
    }

    /// Focus arrived before the 0.15 s retry: the focus handler announces it, and the retry,
    /// seeing it already known, must not be what decides (it used to skip it for good).
    func testFocusBeforeRetryStillAnnouncesOnce() {
        var a = WindowAnnouncements()
        var events: [String] = []
        // Focus handler: adopts and announces before reporting focus.
        if a.needsAnnouncing(9) { a.announced(9); events.append("upsert 9") }
        events.append("focused 9")
        // Retry 0.15 s later: already announced, nothing more.
        if a.needsAnnouncing(9) { events.append("upsert 9 again") }
        expect(events == ["upsert 9", "focused 9"])
    }

    func testRemovalOnlyForAnnouncedWindows() {
        var a = WindowAnnouncements()
        expect(!a.destroyed(3))                                    // never announced: no removal event
        a.announced(4)
        expect(a.destroyed(4) && !a.destroyed(4))                  // once
        expect(a.needsAnnouncing(4))                               // a reused id starts over
    }
}

// MARK: - A closed window stayed "focused" (2026-11-25)

struct FocusedWindowsTests {
    func testClosingTheFocusedWindowClearsIt() {
        var f = FocusedWindows()
        f.set(100, 1)
        f.windowClosed(1, of: 100)                                 // the app's last window closed
        expect(f[100] == nil)
    }

    func testClosingAnotherWindowKeepsFocus() {
        var f = FocusedWindows()
        f.set(100, 1)
        f.windowClosed(2, of: 100)
        f.windowClosed(1, of: 200)                                 // same id, other app
        expect(f[100] == 1)
    }

    func testSetNilAndQuit() {
        var f = FocusedWindows()
        f.set(100, 1); f.set(200, 5)
        f.set(100, nil)
        expect(f[100] == nil && f[200] == 5)
        f.appQuit(200)
        expect(f[200] == nil && f.byPID.isEmpty)
    }
}

// MARK: - ⌃⌘F never restored a window that already filled the screen (2026-11-25)

struct FillToggleTests {
    let area = CGRect(x: 0, y: 25, width: 1280, height: 775)
    let small = CGRect(x: 100, y: 100, width: 600, height: 400)

    func testFillThenRestore() {
        expect(FillToggle.step(current: small, area: area, saved: nil) == .fill)
        expect(FillToggle.step(current: area, area: area, saved: small) == .restore(small))
    }

    func testAlreadyFilledWithNothingSavedDoesNothing() {
        // It used to save the full frame here, so the toggle "restored" to the same frame forever.
        expect(FillToggle.step(current: area, area: area, saved: nil) == .nothing)
        let nearly = area.insetBy(dx: 2, dy: 1)                    // within the 4 pt tolerance
        expect(FillToggle.step(current: nearly, area: area, saved: nil) == .nothing)
    }

    func testNotFilledIgnoresStaleSavedFrame() {
        expect(FillToggle.step(current: small, area: area, saved: CGRect(x: 1, y: 1, width: 9, height: 9)) == .fill)
    }
}

// MARK: - Undo removed (2026-11-25)

struct UndoRemovedTests {
    func testNoUndoActionOrShortcut() {
        expect(Action(rawValue: "snap.undo") == nil)
        expect(!Action.allCases.contains { $0.defaultShortcut == "ctrl+alt+delete" })
        expect(!AppConfiguration.defaultBindings.keys.contains("snap.undo"))
    }

    func testOldConfigWithUndoIsReported() {
        var c = AppConfiguration()
        c.bindings["snap.undo"] = "ctrl+alt+delete"
        expect(c.validate() == ["unknown action \"snap.undo\""])
    }

    func testHelpSheetHasNoUndoRow() {
        let b = Dictionary(uniqueKeysWithValues: AppConfiguration().resolvedBindings().bindings)
        let rows = HelpSheet.sections(bindings: b, states: .init(cross: true, hover: false), gestures: true).flatMap(\.rows)
        expect(!rows.contains { $0.text.lowercased().contains("undo") })
    }
}

// MARK: - App Exposé opening and closing again; slow swipes (2026-11-25)

struct AppExposeTriggerTests {
    func testVerifyWaitIsLongEnoughForASlowDock() {
        // 0.25 s fired the fallback while the Dock was still opening App Exposé.
        expect(AppExposeTrigger.verifyDelay >= 0.5)
    }

    func testFallbackIsRememberedAndForgotten() {
        var t = AppExposeTrigger()
        expect(t.route == .dock)
        t.fallbackWorked()
        expect(t.route == .shortcut)                               // straight to the shortcut, no wait
        t.shortcutFailed()
        expect(t.route == .dock)
    }

    func testDockIsReadOnlyWhenItsStateIsUnknown() {
        expect(!AppExposeTrigger.needsDockRead(stateKnown: true, watching: true))   // every swipe used to read it
        expect(AppExposeTrigger.needsDockRead(stateKnown: false, watching: true))
        expect(AppExposeTrigger.needsDockRead(stateKnown: true, watching: false))
    }
}

// MARK: - Discovery retries (2026-11-25)

struct DiscoveryRetryTests {
    func testBackoffThenGiveUp() {
        expect((0..<DiscoveryRetry.maxAttempts).map { DiscoveryRetry.delay(after: $0) } == [0.25, 0.5, 1, 2])
        expect(DiscoveryRetry.delay(after: DiscoveryRetry.maxAttempts) == nil)
    }

    func testResubscribeAtMostEveryTenSeconds() {
        var l = DiscoveryRetry.Limiter()
        expect(l.allow(now: 100))
        expect(!l.allow(now: 101) && !l.allow(now: 109.9))         // activations in between: skipped
        expect(l.allow(now: 110))
        expect(!l.allow(now: 115))
    }
}

// MARK: - Overview card bitmaps as big as whole cards (2026-11-25)

struct CardBitmapTests {
    let layout = OverviewModel.layout(cardCount: 3, size: CGSize(width: 1280, height: 800))

    func testBitmapCoversOnlyDrawnRows() {
        let card = layout.cardFrames[0].height
        let h0 = OverviewModel.contentHeight(rows: 0, more: 0, cardHeight: card, layout: layout)
        let h3 = OverviewModel.contentHeight(rows: 3, more: 0, cardHeight: card, layout: layout)
        expect(h0 >= layout.rowsTop && h0 < card)
        expect(h3 >= layout.rowsTop + 3 * layout.rowHeight && h3 < card)
        expect(OverviewModel.contentHeight(rows: 3, more: 2, cardHeight: card, layout: layout) > h3)   // room for "+N more"
    }

    func testNeverTallerThanTheCard() {
        let card = layout.cardFrames[0].height
        expect(OverviewModel.contentHeight(rows: 100, more: 5, cardHeight: card, layout: layout) == card)
        expect(OverviewModel.contentHeight(rows: layout.maxRows, more: 1, cardHeight: card, layout: layout) <= card)
    }
}

// MARK: - Fast ⌥ N moved windows to another workspace (2026-11-25)

/// Replays quick workspace switches where each switch starts before the previous one's window
/// moves have been read back (what the engine sees lags what was asked for).
struct FastWorkspaceSwitchTests {
    let d = Display(id: 1, name: "Built-in", isBuiltin: true, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775), uuid: "D1")
    let parkedFrame = CGRect(x: 1279, y: 759, width: 600, height: 400)

    struct Sim {
        var state = WorkspaceState()
        var moves = MovesInFlight()
        /// Frames as the engine knows them (lagging: updated only by `settle`).
        var seen: [UInt32: CGRect]
        /// Frames the queued moves will produce.
        var pending: [UInt32: CGRect] = [:]
    }

    func visible(_ s: Sim) -> [UInt32] {
        s.seen.keys.sorted().filter { id in
            !s.state.isParked(id) && FocusLogic.visibleFraction(s.seen[id]!, on: d.frame) >= FocusLogic.minVisibleFraction
        }
    }

    /// What WorkspaceManager.switchTo does, without applying any move yet.
    func switchTo(_ n: Int, _ s: inout Sim) {
        let cur = s.state.activeWorkspace(d.uuid)
        guard n != cur else { return }
        let leaving = WorkspaceSwitch.leaving(visible: visible(s), restoring: s.moves.restoring,
                                              isParked: { s.state.isParked($0) },
                                              displayOf: { Geometry.display(for: $0, in: [d])?.id }, display: d.id)
        for (z, id) in leaving.enumerated() {
            let f = s.moves.restoreTarget(id) ?? s.seen[id]!
            s.state.hidden[String(id)] = ParkedWindow(ws: cur, scr: d.uuid, x: f.minX - d.visibleFrame.minX,
                                                      y: f.minY - d.visibleFrame.minY, w: f.width, h: f.height, z: z + 1)
            s.moves.parkStarted(id)
            s.pending[id] = parkedFrame
        }
        for (id, e) in s.state.incoming(n, on: d.uuid) {
            s.state.hidden.removeValue(forKey: String(id))
            let target = e.relativeFrame.offsetBy(dx: d.visibleFrame.minX, dy: d.visibleFrame.minY)
            s.moves.restoreStarted(id, to: target)
            s.pending[id] = target
        }
        s.state.active[d.uuid] = n
    }

    /// Every queued move lands and is read back.
    func settle(_ s: inout Sim) {
        for (id, f) in s.pending {
            s.seen[id] = f
            if s.moves.isParking(id) { s.moves.parkFinished(id) }
            if s.moves.restoreTarget(id) != nil { s.moves.restoreFinished(id) }
        }
        s.pending.removeAll()
    }

    /// Workspace of each window: parked entry, or the active one if on screen.
    func where_(_ s: Sim) -> [UInt32: Int] {
        var out: [UInt32: Int] = [:]
        for id in s.seen.keys {
            if let e = s.state.parked(id) { out[id] = e.ws }
            else if FocusLogic.visibleFraction(s.seen[id]!, on: d.frame) >= FocusLogic.minVisibleFraction { out[id] = s.state.activeWorkspace(d.uuid) }
        }
        return out
    }

    func start() -> Sim {
        // 1 on workspace 1 (showing), 2 on workspace 2, 3 on workspace 3.
        var s = Sim(seen: [1: CGRect(x: 0, y: 25, width: 600, height: 400), 2: parkedFrame, 3: parkedFrame])
        s.state.active[d.uuid] = 1
        s.state.hidden["2"] = ParkedWindow(ws: 2, scr: d.uuid, x: 100, y: 0, w: 600, h: 400, z: 1)
        s.state.hidden["3"] = ParkedWindow(ws: 3, scr: d.uuid, x: 200, y: 0, w: 600, h: 400, z: 1)
        return s
    }

    func testSecondSwitchBeforeTheFirstLandsKeepsWindowsOnTheirWorkspaces() {
        var s = start()
        switchTo(2, &s)                          // ⌥2: window 2 on its way back
        switchTo(3, &s)                          // ⌥3 right away: window 2 hasn't landed yet
        settle(&s)
        expect(where_(s) == [1: 1, 2: 2, 3: 3])  // window 2 used to end up on workspace 3
        // Window 2 keeps its own frame (the restore's target), not the parked one.
        expect(s.state.parked(2)?.relativeFrame == CGRect(x: 100, y: 0, width: 600, height: 400))
    }

    func testRapidRoundTrip() {
        var s = start()
        switchTo(2, &s); switchTo(3, &s); switchTo(1, &s); switchTo(2, &s)
        settle(&s)
        expect(where_(s) == [1: 1, 2: 2, 3: 3])
        switchTo(3, &s); settle(&s); switchTo(1, &s); switchTo(3, &s); switchTo(2, &s); settle(&s)
        expect(where_(s) == [1: 1, 2: 2, 3: 3] && s.state.activeWorkspace(d.uuid) == 2)
    }

    func testSlowSwitchesStillWork() {
        var s = start()
        for n in [2, 3, 1, 3, 2, 1] { switchTo(n, &s); settle(&s); expect(where_(s) == [1: 1, 2: 2, 3: 3]) }
    }

    func testParkCountsSurviveOverlap() {
        var m = MovesInFlight()
        m.parkStarted(5)                          // switch 1 parks it
        m.restoreStarted(5, to: .zero)            // switch 2 brings it back
        m.parkStarted(5)                          // switch 3 parks it again
        m.parkFinished(5)                         // switch 1's park lands
        expect(m.isParking(5))                    // a set forgot this, and the window was dropped
        m.parkFinished(5)
        expect(!m.isParking(5))
        m.parkFinished(5)                         // extra finish: harmless
        expect(!m.isParking(5))
    }

    func testRestoreTargetIsTheNewest() {
        var m = MovesInFlight()
        let a = CGRect(x: 1, y: 1, width: 10, height: 10), b = CGRect(x: 2, y: 2, width: 10, height: 10)
        m.restoreStarted(7, to: a); m.restoreStarted(7, to: b)
        expect(m.restoreTarget(7) == b)
        m.restoreFinished(7)
        expect(m.restoreTarget(7) == b)           // still one in flight
        m.restoreFinished(7)
        expect(m.restoreTarget(7) == nil && m.restoring.isEmpty)
    }

    func testLeavingSkipsParkedAndOtherDisplays() {
        let other: UInt32 = 2
        let l = WorkspaceSwitch.leaving(visible: [10, 11], restoring: [12: .zero, 13: .zero, 10: .zero, 14: .zero],
                                        isParked: { $0 == 13 }, displayOf: { _ in 1 }, display: 1)
        expect(l == [12, 14, 10, 11])             // incoming first, then visible; 13 parked, 10 not twice
        expect(WorkspaceSwitch.leaving(visible: [10], restoring: [12: .zero], isParked: { _ in false },
                                       displayOf: { _ in other }, display: 1) == [10])
    }
}
