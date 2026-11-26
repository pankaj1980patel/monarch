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
        var seq = 1
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
            s.moves.restoreStarted(id, to: target, seq: s.seq)
            s.pending[id] = target
        }
        s.state.active[d.uuid] = n
    }

    /// Every queued move lands and is read back.
    func settle(_ s: inout Sim) {
        for (id, f) in s.pending {
            s.seen[id] = f
            if s.moves.isParking(id) { s.moves.parkFinished(id) }
            if s.moves.restoreTarget(id) != nil { s.moves.restoreArrived(id) }      // seen on screen
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
        m.restoreStarted(5, to: .zero, seq: 2)    // switch 2 brings it back
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
        m.restoreStarted(7, to: a, seq: 1); m.restoreStarted(7, to: b, seq: 2)
        expect(m.restoreTarget(7) == b)
        m.restoreExpired(7, seq: 1)               // the older restore's safety net: ignored
        expect(m.restoreTarget(7) == b)
        m.restoreExpired(7, seq: 2)
        expect(m.restoreTarget(7) == nil && m.restoring.isEmpty)
    }

    /// A busy app (Chrome) can take longer than any short timer to move a window back. It must
    /// stay "on its way" until it's seen, so a ⌥ N meanwhile still takes it along.
    func testSlowRestoreStaysInFlightUntilSeen() {
        var m = MovesInFlight()
        m.restoreStarted(3, to: .zero, seq: 1)
        // No timer in between: still on its way (the 0.6 s timer dropped it here).
        expect(m.restoreTarget(3) != nil)
        m.restoreArrived(3)
        expect(m.restoreTarget(3) == nil)
        expect(MovesInFlight.restoreSafetyNet >= 3)
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

// MARK: - Overlapping workspace operations (2026-11-26)

struct OperationSequenceTests {
    /// ⌥2 then ⌥3 quickly: switch 2 finishes last. It must not focus its top window (which
    /// switch 3 just parked): typing would go into a window you can't see.
    func testOlderSwitchFinishingLateDoesNotFocus() {
        var ops = OperationSequence()
        let s2 = ops.begin(displays: ["D1"], windows: [20, 10])         // parks 10, restores 20
        let s3 = ops.begin(displays: ["D1"], windows: [30, 20])         // parks 20, restores 30
        expect(ops.isLatest(s3, on: "D1"))                              // switch 3 may focus
        expect(!ops.isLatest(s2, on: "D1"))                             // switch 2's early / final focus: skipped
    }

    func testOtherDisplaysAreIndependent() {
        var ops = OperationSequence()
        let a = ops.begin(displays: ["D1"], windows: [1])
        let b = ops.begin(displays: ["D2"], windows: [2])
        expect(ops.isLatest(a, on: "D1") && ops.isLatest(b, on: "D2"))
        let all = ops.begin(displays: ["D1", "D2"], windows: [])        // ⌃⌥⇧ 0 touches every display
        expect(!ops.isLatest(a, on: "D1") && !ops.isLatest(b, on: "D2") && ops.isLatest(all, on: "D2"))
    }

    /// A late "not moved" from an older park must not delete the entry a newer switch saved.
    func testLateResultsForAWindowMovedSinceAreDropped() {
        var ops = OperationSequence()
        var hidden: [UInt32: Int] = [:]                                // window → workspace
        let s1 = ops.begin(displays: ["D1"], windows: [5]); hidden[5] = 1
        let s2 = ops.begin(displays: ["D1"], windows: [5]); hidden[5] = 4      // moved again
        // s1's park reports late: "not moved" would remove the entry.
        if ops.isLatest(s1, for: 5) { hidden.removeValue(forKey: 5) }
        expect(hidden[5] == 4)
        // s2's own result still applies.
        expect(ops.isLatest(s2, for: 5))
        // Windows the newer switch didn't touch keep the older switch's results.
        let s3 = ops.begin(displays: ["D1"], windows: [6])
        _ = ops.begin(displays: ["D1"], windows: [7])
        expect(ops.isLatest(s3, for: 6))
    }

    func testForgottenWindowAcceptsAnyResult() {
        var ops = OperationSequence()
        let s = ops.begin(displays: ["D1"], windows: [9])
        ops.forget(window: 9)                                           // closed
        expect(ops.isLatest(s, for: 9) && ops.isLatest(1_000, for: 42))
    }
}

// MARK: - Holding Tab in ⌘Tab keeps moving (2026-11-26)

struct SwitcherRepeatTests {
    func testUsesSystemSettingsWithinLimits() {
        let t = SwitcherRepeat.timing(systemDelay: 0.5, systemInterval: 0.083)
        expect(t.delay == 0.5 && t.interval == 0.083)
        let fast = SwitcherRepeat.timing(systemDelay: 0.05, systemInterval: 0.015)   // fastest settings
        expect(fast.delay == 0.2 && fast.interval == 0.06)                        // still readable
        let slow = SwitcherRepeat.timing(systemDelay: 2, systemInterval: 2)
        expect(slow.delay == 0.8 && slow.interval == 0.25)
    }

    func testRepeatedStepsWrap() {
        var i = 1
        for _ in 0..<5 { i = SwitcherLogic.move(i, by: 1, count: 4) }
        expect(i == 2)
        for _ in 0..<3 { i = SwitcherLogic.move(i, by: -1, count: 4) }
        expect(i == 3)
    }
}

// MARK: - Slack lost from workspace 8, ⌘Tab couldn't bring it up (2026-11-26)

struct ParkedNudgeTests {
    let e = ParkedWindow(ws: 8, scr: "D1", x: 0, y: 0, w: 1280, h: 800, z: 1, px: 1279, py: 759)
    let display = Display(id: 1, name: "Built-in", isBuiltin: true, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                          visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775), uuid: "D1")

    func testMacOSNudgingAParkedWindowKeepsItParked() {
        // Parked at y 759, then macOS moved it to 768 (still off screen). This used to read as
        // "moved back by hand" and the window lost its workspace.
        let nudged = CGRect(x: 1279, y: 768, width: 1280, height: 800)
        expect(Parking.update(for: nudged, entry: e, offScreen: true) == .relearn(CGPoint(x: 1279, y: 768)))
        expect(Parking.update(for: CGRect(x: 1280, y: 760, width: 1280, height: 800), entry: e, offScreen: true) == .keep)
    }

    func testBroughtBackOnScreenIsUnparked() {
        expect(Parking.update(for: CGRect(x: 100, y: 100, width: 800, height: 600), entry: e, offScreen: false) == .unparked)
    }

    func testUnreadSpotIsLearnedWhileOffScreen() {
        let unread = ParkedWindow(ws: 8, scr: "D1", x: 0, y: 0, w: 1280, h: 800, z: 1)
        expect(Parking.update(for: CGRect(x: 1279, y: 768, width: 1280, height: 800), entry: unread, offScreen: true)
               == .relearn(CGPoint(x: 1279, y: 768)))
        expect(Parking.update(for: CGRect(x: 0, y: 25, width: 1280, height: 775), entry: unread, offScreen: false) == .unparked)
    }

    func testStrandedWindowIsRecognised() {
        let off = CGRect(x: 1279, y: 768, width: 1280, height: 800)
        expect(WorkspaceSwitch.isStranded(parked: false, moving: false, minimized: false, frame: off, displays: [display]))
        // Parked, being moved, minimized, or on screen: not stranded.
        expect(!WorkspaceSwitch.isStranded(parked: true, moving: false, minimized: false, frame: off, displays: [display]))
        expect(!WorkspaceSwitch.isStranded(parked: false, moving: true, minimized: false, frame: off, displays: [display]))
        expect(!WorkspaceSwitch.isStranded(parked: false, moving: false, minimized: true, frame: off, displays: [display]))
        expect(!WorkspaceSwitch.isStranded(parked: false, moving: false, minimized: false,
                                           frame: CGRect(x: 100, y: 100, width: 600, height: 400), displays: [display]))
    }
}

// MARK: - Config overwritten with defaults (review 2026-11-26, F1 / F2)

struct ConfigFileTests {
    func testMissingFileIsFirstRun() {
        let o = ConfigFile.interpret(exists: false, data: nil)
        expect(ConfigFile.mayWrite(after: o) && ConfigFile.resolve(o).error == nil)
    }

    func testBrokenFileIsNeverOverwritten() {
        // A typo mid-edit: invalid JSON. Defaults in memory, the file left alone.
        let o = ConfigFile.interpret(exists: true, data: Data(#"{"snappingEnabled": tru"#.utf8))
        expect(!ConfigFile.mayWrite(after: o))
        let (c, err) = ConfigFile.resolve(o)
        expect(err != nil && c.gestures == nil)       // gestures nil used to look like a first run → save
    }

    func testUnreadableFileIsNeverOverwritten() {
        let o = ConfigFile.interpret(exists: true, data: nil)          // exists, but reading failed
        expect(!ConfigFile.mayWrite(after: o) && ConfigFile.resolve(o).error != nil)
    }

    func testGoodFileLoads() {
        let o = ConfigFile.interpret(exists: true, data: Data(#"{"sameAppHover": true}"#.utf8))
        expect(ConfigFile.mayWrite(after: o))
        let (c, err) = ConfigFile.resolve(o)
        expect(err == nil && c.sameAppHover)
    }
}

// MARK: - Windows left parked after a crash (review 2026-11-26, F8)

struct ParkedOrphanTests {
    let d = Display(id: 1, name: "Built-in", isBuiltin: true, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                    visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775), uuid: "D1")

    func testRealParkedFramesAreRecognised() {
        // Frames macOS actually left parked windows at today.
        expect(Parking.looksParked(CGRect(x: 1279, y: 759, width: 1280, height: 800), displays: [d]))
        expect(Parking.looksParked(CGRect(x: 1279, y: 768, width: 853, height: 800), displays: [d]))
        expect(Parking.looksParked(CGRect(x: -599, y: 799, width: 600, height: 400), displays: [d]))   // left spot
    }

    func testOtherOffScreenWindowsAreLeftAlone() {
        // An app's own off-screen window (not where Monarch parks) must not pop up at launch.
        expect(!Parking.looksParked(CGRect(x: -10_000, y: -10_000, width: 400, height: 300), displays: [d]))
        expect(!Parking.looksParked(CGRect(x: 100, y: 100, width: 800, height: 600), displays: [d]))
    }

    func testClosedWindowLeavesNothingInFlight() {
        var m = MovesInFlight()
        m.parkStarted(4); m.parkStarted(4); m.restoreStarted(4, to: .zero, seq: 1)
        m.forget(4)
        expect(!m.isParking(4) && m.restoreTarget(4) == nil)
    }
}

// MARK: - Build script installed a stale binary (review 2026-11-26, F3)

struct BuildScriptTests {
    func testFailedBuildStopsTheScript() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
        let script = try String(contentsOf: url, encoding: .utf8)
        // The build line must not swallow its exit status (`… | grep … || true` did).
        let buildLines = script.split(separator: "\n").filter { $0.contains("swift build -c release --product") }
        expect(!buildLines.isEmpty)
        expect(buildLines.allSatisfy { !$0.contains("|| true") && !$0.contains("| grep") })
        expect(script.contains("build failed: nothing installed"))
    }
}

// MARK: - Thumb rejection (2026-11-26)

/// A thumb resting on the trackpad must not change what a swipe is.
struct ThumbRejectionTests {
    typealias Frame = [(Int32, Float, Float)]
    let thumb: (Int32, Float, Float) = (9, 0.15, 0.08)                // low on the trackpad, not moving

    /// Swipe frames: `fingers` fingers moving by (dx, dy) in `steps` steps, plus the resting thumb.
    func swipe(_ fingers: Int, dx: Float, dy: Float, steps: Int = 8, withThumb: Bool = true, thumbMoves: Bool = false) -> [Frame] {
        (0...steps).map { k in
            let t = Float(k) / Float(steps)
            var f: Frame = (0..<fingers).map { (Int32($0 + 1), 0.35 + Float($0) * 0.1 + dx * t, 0.45 + dy * t) }
            if withThumb { f.append((thumb.0, thumb.1 + (thumbMoves ? dx * t : 0), thumb.2 + (thumbMoves ? dy * t : 0))) }
            return f
        } + [[]]                                                        // lift
    }

    func run(_ frames: [Frame], config: GestureConfig = GestureConfig()) -> [GestureOutput] {
        var r = GestureRecognizer(config: config)
        var out: [GestureOutput] = []
        for (i, f) in frames.enumerated() {
            let pts = f.map { TouchPoint(id: $0.0, x: $0.1, y: $0.2) }
            let o = pts.withUnsafeBufferPointer { r.process($0, time: Double(i) * 0.01) }
            if !o.isEmpty { out.append(o) }
        }
        return out
    }

    func testThumbPlusTwoFingersIsAScroll() {
        // Two-finger scroll with a resting thumb: three touches, but no three-finger gesture.
        let o = run(swipe(2, dx: 0, dy: 0.2))
        expect(o.allSatisfy { $0.locked == nil && $0.crossed == nil && $0.ended == nil })
    }

    func testThumbPlusThreeFingersIsAThreeFingerSwipe() {
        // Four touches; the resting one is the thumb: a three-finger swipe up (overview), not four.
        let o = run(swipe(3, dx: 0, dy: 0.2))
        let locked = o.compactMap(\.locked).first
        expect(locked?.fingers == 3 && locked?.axis == .vertical && locked!.displacement > 0)
        expect(o.compactMap(\.ended).first?.fingers == 3)
    }

    func testThumbPlusThreeFingersHorizontal() {
        let o = run(swipe(3, dx: -0.2, dy: 0))
        expect(o.compactMap(\.locked).first.map { $0.fingers == 3 && $0.axis == .horizontal } == true)
    }

    func testFourMovingFingersStayFour() {
        // No false rejection: a real four-finger swipe (all moving) is still four fingers.
        let o = run(swipe(4, dx: 0.2, dy: 0, withThumb: false))
        expect(o.compactMap(\.locked).first?.fingers == 4)
    }

    func testAThumbThatSwipesCounts() {
        // Thumb used as one of the swiping fingers: it moves with them, so it counts.
        let o = run(swipe(2, dx: 0, dy: 0.2, thumbMoves: true))
        expect(o.compactMap(\.locked).first?.fingers == 3)
    }

    func testTurnedOffCountsTheThumb() {
        var c = GestureConfig(); c.thumbRejection = false
        let o = run(swipe(3, dx: 0, dy: 0.2), config: c)
        expect(o.compactMap(\.locked).first?.fingers == 4)              // the old behaviour
    }

    func testSettingDecodesAndDefaultsOn() throws {
        expect(GestureConfig().thumbRejection)
        let off = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"thumbRejection": false}"#.utf8))
        expect(!off.thumbRejection)
        let old = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"threeFinger": 0.07}"#.utf8))
        expect(old.thumbRejection)                                     // configs from before: on
    }
}

// MARK: - Motion consensus: which contacts are the gesture (2026-11-26)

/// Cases from the thumb-detection design review. Frames are 8 ms apart, like a trackpad.
struct MotionConsensusTests {
    /// One contact: where it lands, how far it moves per frame, when it starts moving and
    /// when it lifts (frame numbers; nil = stays down until everything lifts).
    struct Contact {
        var id: Int32, x: Float, y: Float
        var dx: Float = 0, dy: Float = 0
        var moveFrom = 0, liftAt: Int? = nil, landAt = 0
    }

    func run(_ contacts: [Contact], frames: Int = 16, config: GestureConfig = GestureConfig()) -> [GestureOutput] {
        var r = GestureRecognizer(config: config)
        var out: [GestureOutput] = []
        for f in 0...frames {
            let pts: [TouchPoint] = f == frames ? [] : contacts.compactMap { c in
                guard f >= c.landAt, c.liftAt.map({ f < $0 }) ?? true else { return nil }
                let k = Float(max(0, f - c.moveFrom))
                return TouchPoint(id: c.id, x: c.x + c.dx * k, y: c.y + c.dy * k)
            }
            let o = pts.withUnsafeBufferPointer { r.process($0, time: Double(f) * 0.008) }
            if !o.isEmpty { out.append(o) }
        }
        return out
    }
    func fingers(_ n: Int, dx: Float = 0, dy: Float = 0, x: Float = 0.4) -> [Contact] {
        (0..<n).map { Contact(id: Int32($0 + 1), x: x + Float($0) * 0.08, y: 0.5, dx: dx, dy: dy) }
    }
    func lockedFingers(_ o: [GestureOutput]) -> Int? { o.compactMap(\.locked).first?.fingers }

    func testThumbAnywhereInLeftThirdGivesThreeFingers() {
        // Top-left, middle-left, bottom-left, and just inside the left third.
        for (x, y) in [(0.05, 0.95), (0.05, 0.5), (0.05, 0.05), (0.3, 0.1)] as [(Float, Float)] {
            let o = run(fingers(3, dy: 0.01, x: 0.45) + [Contact(id: 9, x: x, y: y)])
            expect(lockedFingers(o) == 3)
        }
    }

    func testRestingContactOutsideLeftThirdIsAFinger() {
        // Thumb detection is only in the left third: a still contact elsewhere counts.
        for (x, y) in [(0.95, 0.95), (0.95, 0.05), (0.5, 0.05), (0.34, 0.5)] as [(Float, Float)] {
            let o = run(fingers(3, dy: 0.01, x: 0.45) + [Contact(id: 9, x: x, y: y)], frames: 24)
            expect(lockedFingers(o) == 4)
        }
    }

    func testTwoFingersPlusContactOnTheRightIsThreeFingers() {
        // Without a contact in the left third, nothing is left out (as with thumbRejection off).
        let o = run([Contact(id: 1, x: 0.5, y: 0.5, dy: 0.01), Contact(id: 2, x: 0.6, y: 0.5, dy: 0.01),
                     Contact(id: 9, x: 0.9, y: 0.1)], frames: 24)
        expect(lockedFingers(o) == 3)
    }

    func testFourFingersPlusContactOnTheRightCancels() {
        let o = run(fingers(4, dx: -0.01, x: 0.4) + [Contact(id: 9, x: 0.95, y: 0.1)])
        expect(o.allSatisfy { $0.locked == nil })
    }

    func testFourFingersPlusThumbIsFour() {
        let o = run(fingers(4, dx: -0.01, x: 0.3) + [Contact(id: 9, x: 0.1, y: 0.1)])
        expect(lockedFingers(o) == 4 && o.compactMap(\.locked).first?.axis == .horizontal)
    }

    func testFiveMovingFingersCancel() {
        let o = run(fingers(5, dy: 0.01, x: 0.2))
        expect(o.allSatisfy { $0.locked == nil })
    }

    func testAllStillDoesNothing() {
        let o = run(fingers(3) + [Contact(id: 9, x: 0.1, y: 0.1)])
        expect(o.allSatisfy { $0.locked == nil && $0.ended == nil })
    }

    func testPinchIsNotASwipe() {
        // Fingers moving toward each other: no group moves together.
        let o = run([Contact(id: 1, x: 0.3, y: 0.5, dx: 0.01), Contact(id: 2, x: 0.7, y: 0.5, dx: -0.01),
                     Contact(id: 3, x: 0.5, y: 0.3, dy: 0.01), Contact(id: 4, x: 0.5, y: 0.7, dy: -0.01)])
        expect(o.allSatisfy { $0.locked == nil })
    }

    func testThumbDriftingWithTheHandIsLeftOut() {
        // The thumb moves a little (13% of the fingers) in the same direction.
        let o = run(fingers(3, dy: 0.01) + [Contact(id: 9, x: 0.1, y: 0.1, dy: 0.0013)])
        expect(lockedFingers(o) == 3)
    }

    func testThumbDraggingSidewaysIsLeftOut() {
        let o = run(fingers(3, dy: 0.01) + [Contact(id: 9, x: 0.1, y: 0.1, dx: 0.008)])
        expect(lockedFingers(o) == 3 && o.compactMap(\.locked).first?.axis == .vertical)
    }

    func testLateStartingFourthFingerStillCounts() {
        // A real four-finger swipe whose last finger starts moving two frames (16 ms) late.
        var c = fingers(4, dx: 0.01, x: 0.3)
        c[3].moveFrom = 2
        expect(lockedFingers(run(c)) == 4)
    }

    func testSlowSwipeStillLocks() {
        // Slow is fine: what matters is moving together, not speed.
        let o = run(fingers(3, dy: 0.0025) + [Contact(id: 9, x: 0.1, y: 0.9)], frames: 40)
        expect(lockedFingers(o) == 3)
    }

    func testThumbLiftingMidGestureCausesNoJump() {
        let o = run(fingers(3, dy: 0.01) + [Contact(id: 9, x: 0.1, y: 0.1, liftAt: 8)])
        let crossings = o.compactMap { $0.crossed ?? $0.ended }
        expect(lockedFingers(o) == 3)
        expect(crossings.allSatisfy { $0.displacement > 0 })
        // The final displacement is the fingers' own travel (15 frames × 0.01).
        expect(close(o.compactMap(\.ended).first?.displacement ?? 0, 0.15, 0.002))
    }

    func testThumbLandingAfterLockIsIgnored() {
        let o = run(fingers(3, dy: 0.01) + [Contact(id: 9, x: 0.1, y: 0.1, landAt: 9)])
        expect(lockedFingers(o) == 3 && o.compactMap(\.ended).first?.fingers == 3)
    }

    func testGestureEndsWhenItsFingersLiftEvenWithThumbDown() {
        // Fingers lift at frame 10; the thumb stays until the end. The gesture must end then,
        // not when the thumb finally lifts (it held the overview open before).
        var c = fingers(3, dy: 0.01)
        for i in c.indices { c[i].liftAt = 10 }
        c.append(Contact(id: 9, x: 0.1, y: 0.1))
        var r = GestureRecognizer(config: GestureConfig())
        var endedAt: Int?, liftedAt: Int?
        for f in 0...16 {
            let pts: [TouchPoint] = f == 16 ? [] : c.compactMap { k in
                guard k.liftAt.map({ f < $0 }) ?? true else { return nil }
                return TouchPoint(id: k.id, x: k.x + k.dx * Float(f), y: k.y + k.dy * Float(f))
            }
            let o = pts.withUnsafeBufferPointer { r.process($0, time: Double(f) * 0.008) }
            if o.ended != nil { endedAt = f }
            if o.lifted { liftedAt = liftedAt ?? f }
        }
        expect(endedAt == 10 && liftedAt == 10)
    }

    func testDroppedFramesRestartTheMeasurement() {
        var r = GestureRecognizer(config: GestureConfig())
        let a = fingers(3).map { TouchPoint(id: $0.id, x: $0.x, y: $0.y) }
        let b = fingers(3).map { TouchPoint(id: $0.id, x: $0.x, y: $0.y + 0.05) }
        _ = a.withUnsafeBufferPointer { r.process($0, time: 0) }
        // 0.3 s later (frames were dropped): the jump isn't taken as movement.
        let o = b.withUnsafeBufferPointer { r.process($0, time: 0.3) }
        expect(o.locked == nil)
    }
}
