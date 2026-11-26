import Foundation
import MonarchCore

// MARK: - Functionality review fixes (2026-11-26)

/// The menu's snapping toggle and ⌃⌥ M / ⌃⌥ H must not write Monarch's copy over config.json.
struct ConfigPatchTests {
    func json(_ d: Data?) -> [String: Any]? { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }

    func testKeepsEditsNotYetReloaded() {
        // The user changed axTimeout and a binding but hasn't pressed ⌃⌥⇧ R; then toggles ⌃⌥ H.
        let file = Data(#"{"axTimeout": 1.5, "bindings": {"snap.left": "ctrl+alt+j"}, "sameAppHover": false}"#.utf8)
        let out = json(ConfigFile.patch(file, exists: true, changes: ["sameAppHover": true]))
        expect(out?["sameAppHover"] as? Bool == true)
        expect(out?["axTimeout"] as? Double == 1.5)
        expect((out?["bindings"] as? [String: String])?["snap.left"] == "ctrl+alt+j")
        expect(out?.count == 3)                                  // nothing of Monarch's copy added
    }

    func testBrokenFileIsNeverWritten() {
        expect(ConfigFile.patch(Data(#"{"axTimeout": 0.3,, }"#.utf8), exists: true, changes: ["snappingEnabled": false]) == nil)
        expect(ConfigFile.patch(nil, exists: true, changes: ["snappingEnabled": false]) == nil)     // unreadable
        expect(ConfigFile.patch(Data("[1, 2]".utf8), exists: true, changes: ["snappingEnabled": false]) == nil)
    }

    func testNoFileWritesDefaultsWithTheChange() throws {
        let out = try JSONDecoder().decode(AppConfiguration.self, from: ConfigFile.patch(nil, exists: false, changes: ["snappingEnabled": false])!)
        var want = AppConfiguration(); want.snappingEnabled = false
        expect(out == want)
    }
}

/// Launch checks the config like ⌃⌥⇧ R: out-of-range values aren't applied.
struct LaunchValidationTests {
    func testOutOfRangeValuesFallBackToDefaults() {
        var c = AppConfiguration()
        c.axTimeout = 60
        var g = GestureConfig(); g.ratio = 0.2; g.lockDistance = 3; g.thumbAreaWidth = 0.9; g.threeFinger = 0.1
        c.gestures = g
        expect(c.validate().count == 4)
        let fixed = c.withDefaultsForOutOfRange()
        expect(fixed.validate().isEmpty)
        expect(fixed.axTimeout == AppConfiguration().axTimeout && fixed.gestures?.ratio == GestureConfig().ratio)
        expect(fixed.gestures?.threeFinger == 0.1)               // values in range are kept
    }
}

/// A monitor that blinks off and on must not bring every window back.
struct DisplayArrangementTests {
    let a: Set<String> = ["builtin@0,0,1512,982", "ext@1512,0,2560,1440"]
    let b: Set<String> = ["builtin@0,0,1512,982"]

    func testBlinkBackToTheSameSetupDoesNothing() {
        var d = DisplayArrangement(a)
        expect(d.changed(to: b) == .scheduleRestore)            // monitor off
        expect(d.changed(to: a) == .cancelPending)              // back on before it settled
        expect(!d.settle(a))
    }

    func testARealChangeRestoresOnce() {
        var d = DisplayArrangement(a)
        expect(d.changed(to: b) == .scheduleRestore)
        expect(d.settle(b))
        expect(!d.settle(b))                                     // settled: no second restore
        expect(d.changed(to: a) == .scheduleRestore)            // plugging it back is a change again
    }
}

/// Only the macOS shortcuts Monarch registered itself are turned off.
struct SystemShortcutTests {
    func testOnlyOwnedShortcutsAreTurnedOff() {
        let cmdTab = Shortcut("cmd+tab")!, cmdShiftTab = Shortcut("cmd+shift+tab")!, other = Shortcut("ctrl+alt+left")!
        expect(SystemShortcuts.owned(by: [cmdTab, other]) == [1])
        expect(SystemShortcuts.owned(by: [cmdTab, cmdShiftTab, Shortcut("cmd+`")!]) == [1, 2, 6])
        expect(SystemShortcuts.owned(by: [other]).isEmpty)
        expect(SystemShortcuts.owned(by: []).isEmpty)
    }

    func testDefaultBindingsOwnAllThree() {
        let shortcuts = AppConfiguration().resolvedBindings().bindings.map(\.1)
        expect(SystemShortcuts.owned(by: shortcuts) == [1, 2, 6])
    }
}

/// Window ids restart at boot: entries from an earlier boot must not match new windows.
struct BootSessionTests {
    func state(boot: String?) -> WorkspaceState {
        var s = WorkspaceState()
        s.boot = boot
        s.hidden["101"] = ParkedWindow(ws: 3, scr: "ext", x: 0, y: 0, w: 100, h: 100, z: 1)
        s.active["ext"] = 3
        return s
    }

    func testEntriesFromAnEarlierBootAreDropped() {
        var s = state(boot: "boot-A")
        expect(s.adopt(boot: "boot-B"))
        expect(s.hidden.isEmpty && s.active.isEmpty && s.boot == "boot-B")
    }

    func testSameBootKeepsEverything() {
        var s = state(boot: "boot-A")
        expect(!s.adopt(boot: "boot-A"))
        expect(s.hidden.count == 1 && s.activeWorkspace("ext") == 3)
    }

    func testFilesWithoutABootAreKeptAndStamped() throws {
        var s = state(boot: nil)
        expect(!s.adopt(boot: "boot-A") && s.hidden.count == 1 && s.boot == "boot-A")
        // Older files (and Hammerspoon's) have no "boot" key and still load.
        let old = try JSONDecoder().decode(WorkspaceState.self, from: Data(#"{"active": {}, "hidden": {}}"#.utf8))
        expect(old.boot == nil)
        let round = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        expect(round.boot == "boot-A")
    }
}

/// A rebuild restarts Monarch with SIGHUP, so windows on hidden workspaces stay parked; a real
/// quit (SIGTERM, the menu) brings them back.
struct QuitRestoreTests {
    func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testBuildScriptRestartsWithSIGUSR1AndWaits() throws {
        // SIGHUP is what a closing terminal sends: it must stay a normal quit.
        let script = try source("scripts/build-app.sh")
        let kills = script.split(separator: "\n").filter { $0.contains("pkill") }
        expect(!kills.isEmpty && kills.allSatisfy { $0.contains("-USR1") })
        expect(script.contains("pgrep -x \"$APP_NAME\" >/dev/null || break"))
    }

    func testHandoverIdentifiesTheNewCopyByPid() throws {
        // The agent's copy isn't a registered app while it waits for the handover, so a
        // bundle-id lookup never found it: the old copy stayed, and launchd restarted the
        // agent's copy every few seconds.
        let main = try source("Sources/Monarch/App/main.swift")
        expect(main.contains("postNotificationName(monarchHandoverNote, object: String(me)"))
        let app = try source("Sources/Monarch/App/AppDelegate.swift")
        expect(app.contains("Self.isAnotherCopy(pid)"))
        expect(!app.contains("runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier"))
    }

    func testQuitBringsParkedWindowsBack() throws {
        let app = try source("Sources/Monarch/App/AppDelegate.swift")
        expect(app.contains("workspaces.prepareForQuit(keepParked: restarting)"))
        let main = try source("Sources/Monarch/App/main.swift")
        expect(main.contains("makeSignalSource(signal: SIGUSR1"))
    }
}

/// Which side of the trackpad a resting thumb is looked for on (right- or left-handed).
struct ThumbAreaTests {
    typealias C = MotionConsensusTests.Contact
    let t = MotionConsensusTests()

    func config(_ area: GestureConfig.ThumbArea, width: Double = 1.0 / 3) -> GestureConfig {
        var c = GestureConfig(); c.thumbArea = area; c.thumbAreaWidth = width
        return c
    }

    func testDefaultIsLeftThird() {
        let c = GestureConfig()
        expect(c.thumbArea == .left && close(c.thumbAreaWidth, 1.0 / 3))
        expect(c.inThumbArea(0.2) && !c.inThumbArea(0.5) && !c.inThumbArea(0.9))
    }

    func testRightAreaForLeftHanded() {
        let c = config(.right)
        expect(c.inThumbArea(0.9) && !c.inThumbArea(0.1))
        // Left-handed: the thumb rests on the right, the fingers swipe to its left.
        let thumbRight = t.fingers(3, dy: 0.01, x: 0.3) + [C(id: 9, x: 0.92, y: 0.1)]
        expect(t.lockedFingers(t.run(thumbRight, config: c)) == 3)
        // A thumb on the left (not in a corner) now counts as a finger.
        let thumbLeft = t.fingers(3, dy: 0.01, x: 0.45) + [C(id: 9, x: 0.08, y: 0.5)]
        expect(t.lockedFingers(t.run(thumbLeft, frames: 24, config: c)) == 4)
    }

    func testBothSides() {
        let c = config(.both, width: 0.25)
        expect(c.inThumbArea(0.1) && c.inThumbArea(0.9) && !c.inThumbArea(0.5) && !c.inThumbArea(0.3))
        for x: Float in [0.08, 0.92] {
            expect(t.lockedFingers(t.run(t.fingers(3, dy: 0.01, x: 0.4) + [C(id: 9, x: x, y: 0.1)], config: c)) == 3)
        }
    }

    func testAnywhere() {
        let c = config(.anywhere)
        expect(t.lockedFingers(t.run(t.fingers(3, dy: 0.01, x: 0.2) + [C(id: 9, x: 0.6, y: 0.9)], config: c)) == 3)
    }

    func testWidth() {
        let narrow = config(.left, width: 0.15)
        expect(narrow.inThumbArea(0.1) && !narrow.inThumbArea(0.2))
    }

    func testDecodingAndValidation() throws {
        let g = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"thumbArea": "right", "thumbAreaWidth": 0.25}"#.utf8))
        expect(g.thumbArea == .right && g.thumbAreaWidth == 0.25)
        let old = try JSONDecoder().decode(GestureConfig.self, from: Data("{}".utf8))
        expect(old.thumbArea == .left)                          // configs from before: left third
        var c = AppConfiguration(); var bad = GestureConfig(); bad.thumbAreaWidth = 0.05; c.gestures = bad
        expect(c.validate().contains { $0.contains("thumbAreaWidth") })
        expect((try? JSONDecoder().decode(GestureConfig.self, from: Data(#"{"thumbArea": "middle"}"#.utf8))) == nil)
    }
}

/// A three- or four-finger swipe must not also scroll the window under the mouse.
struct ScrollGuardTests {
    func drop(_ g: inout ScrollGuard, phase: Int = 2, momentum: Int = 0, continuous: Bool = true, _ t: Double) -> Bool {
        g.shouldDrop(phase: phase, momentum: momentum, continuous: continuous, now: t)
    }

    func testFingersLiftingOneByOneDontScroll() {
        var g = ScrollGuard()
        expect(g.frame(device: 0, locked: true, now: 0.0))           // guarding starts: switch the filter on
        expect(!g.frame(device: 0, locked: true, now: 0.05))          // only once
        // Two of the swipe's fingers are still moving (still locked): macOS would scroll.
        expect(drop(&g, phase: 1, 0.1) && drop(&g, 0.15))
        g.frame(device: 0, locked: false, now: 0.2)                   // its fingers are gone
        expect(drop(&g, phase: 4, 0.3))                               // within the tail
        expect(drop(&g, phase: 0, momentum: 2, 0.9))                  // coasting
        expect(!g.isIdle(now: 0.9))
    }

    func testRestingThumbDoesntKeepScrollingBlocked() {
        // The swipe ends while the thumb stays down (frames keep coming, not locked): only the
        // tail and the coasting are suppressed, a new scroll works.
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)
        g.frame(device: 0, locked: false, now: 0.2)
        for k in 1...50 { g.frame(device: 0, locked: false, now: 0.2 + Double(k) * 0.008) }
        expect(!drop(&g, phase: 1, 0.7))                              // a new two-finger scroll
        expect(!drop(&g, phase: 2, 0.75))
    }

    func testMouseWheelIsNeverBlocked() {
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)
        expect(!drop(&g, phase: 0, continuous: false, 0.05))          // during the swipe
        expect(drop(&g, phase: 2, 0.05))                              // the trackpad's scroll is
    }

    func testSecondTrackpadCantEndTheFirstsSwipe() {
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)
        g.frame(device: 1, locked: true, now: 0.01)
        g.frame(device: 1, locked: false, now: 0.05)                  // trackpad B's touch ends
        g.frame(device: 0, locked: true, now: 0.06)
        expect(drop(&g, 0.07))                                        // A is still swiping
        g.frame(device: 0, locked: false, now: 0.1)
        expect(drop(&g, 0.2) && !drop(&g, phase: 1, 0.5))
    }

    func testANewScrollAfterwardsWorks() {
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)
        g.frame(device: 0, locked: false, now: 0.2)
        expect(!drop(&g, phase: 1, 1.0))
        expect(!drop(&g, phase: 2, 1.05))
        expect(!drop(&g, phase: 0, momentum: 2, 1.5))                 // its own coasting is kept
        expect(g.isIdle(now: 1.5))
    }

    func testOrdinaryScrollingIsNeverTouched() {
        var g = ScrollGuard()
        for k in 0..<10 { g.frame(device: 0, locked: false, now: Double(k) * 0.01) }
        expect(!drop(&g, phase: 1, 0.05) && !drop(&g, phase: 0, momentum: 2, 0.3))
        expect(g.isIdle(now: 0.3))                                    // the filter stays off
    }

    func testLostLiftFrameNeverBlocksForever() {
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)                      // then no more frames
        expect(drop(&g, 0.2))
        expect(!drop(&g, phase: 1, 5))
        expect(g.isIdle(now: 5))
    }

    func testCoastingBlockExpires() {
        var g = ScrollGuard()
        g.frame(device: 0, locked: true, now: 0)
        g.frame(device: 0, locked: false, now: 0.1)
        expect(!g.isIdle(now: 1))
        expect(g.isIdle(now: 0.1 + ScrollGuard.momentumMax + 0.01))   // the filter goes off on its own
        expect(!drop(&g, phase: 0, momentum: 2, 0.1 + ScrollGuard.momentumMax + 0.02))
    }

    func testSettingDecodes() throws {
        expect(GestureConfig().blockScroll)
        let off = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"blockScroll": false}"#.utf8))
        expect(!off.blockScroll)
    }
}

/// A contact in a corner of the thumb area is a resting thumb, however it moves.
struct ThumbCornerTests {
    typealias C = MotionConsensusTests.Contact
    let t = MotionConsensusTests()

    func testCornerThumbMovingWithTheFingersIsLeftOut() {
        // Top-left and bottom-left; the thumb drags along with the hand (same direction and
        // distance), which motion alone would take for a fourth finger.
        for y: Float in [0.95, 0.05] {
            let o = t.run(t.fingers(3, dy: 0.01, x: 0.45) + [C(id: 9, x: 0.05, y: y, dy: 0.01)])
            expect(t.lockedFingers(o) == 3)
        }
    }

    func testCornerThumbPlusTwoFingersIsAScroll() {
        // All three move together, but one is the corner thumb: two fingers, no gesture.
        let o = t.run([C(id: 1, x: 0.5, y: 0.5, dy: 0.01), C(id: 2, x: 0.6, y: 0.5, dy: 0.01),
                       C(id: 9, x: 0.05, y: 0.95, dy: 0.01)], frames: 24)
        expect(o.allSatisfy { $0.locked == nil })
    }

    func testCornerFollowsTheThumbArea() {
        var c = GestureConfig()
        expect(c.inThumbCorner(0.05, 0.95) && c.inThumbCorner(0.1, 0.05))
        expect(c.inThumbCorner(0.95, 0.05))                                  // bottom-right too
        expect(!c.inThumbCorner(0.95, 0.95) && !c.inThumbCorner(0.05, 0.5) && !c.inThumbCorner(0.2, 0.95))
        expect(c.effectiveThumbCorners == [.topLeft, .bottomLeft, .bottomRight])
        c.thumbArea = .right
        expect(c.inThumbCorner(0.95, 0.95) && c.inThumbCorner(0.05, 0.05) && !c.inThumbCorner(0.05, 0.95))
        c.thumbArea = .both
        expect(c.inThumbCorner(0.95, 0.05) && c.inThumbCorner(0.05, 0.05))
        c.thumbCorner = 0
        expect(!c.inThumbCorner(0.01, 0.01))
    }

    func testBottomRightContactIsLeftOut() {
        // Right-handed default: something resting bottom-right (palm, other hand) moving along.
        let o = t.run(t.fingers(3, dy: 0.01, x: 0.4) + [C(id: 9, x: 0.95, y: 0.05, dy: 0.01)])
        expect(t.lockedFingers(o) == 3)
    }

    func testChosenCorners() throws {
        let g = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"thumbCorners": ["topLeft", "bottomRight"]}"#.utf8))
        expect(g.effectiveThumbCorners == [.topLeft, .bottomRight])
        expect(g.inThumbCorner(0.05, 0.95) && g.inThumbCorner(0.95, 0.05) && !g.inThumbCorner(0.05, 0.05))
        var none = GestureConfig(); none.thumbCorners = []
        expect(!none.inThumbCorner(0.05, 0.95))
        expect(GestureConfig().thumbCorners == nil)                         // default: from thumbArea
    }

    func testCornersOffCountsAMovingCornerContact() {
        var c = GestureConfig(); c.thumbCorner = 0
        let o = t.run(t.fingers(3, dy: 0.01, x: 0.45) + [C(id: 9, x: 0.05, y: 0.95, dy: 0.01)], config: c)
        expect(t.lockedFingers(o) == 4)
    }

    func testOffWithThumbRejectionOff() {
        var c = GestureConfig(); c.thumbRejection = false
        let o = t.run(t.fingers(3, dy: 0.01, x: 0.45) + [C(id: 9, x: 0.05, y: 0.95, dy: 0.01)], config: c)
        expect(t.lockedFingers(o) == 4)
    }

    func testDecodingAndValidation() throws {
        expect(close(GestureConfig().thumbCorner, 0.15))
        let g = try JSONDecoder().decode(GestureConfig.self, from: Data(#"{"thumbCorner": 0.2}"#.utf8))
        expect(close(g.thumbCorner, 0.2))
        var c = AppConfiguration(); var bad = GestureConfig(); bad.thumbCorner = 0.6; c.gestures = bad
        expect(c.validate().contains { $0.contains("thumbCorner") })
        expect(c.withDefaultsForOutOfRange().gestures?.thumbCorner == GestureConfig().thumbCorner)
    }
}

/// Quitting or restarting right after a switch: entries that no longer match where windows are.
struct InterruptedSwitchTests {
    func entry(ws: Int, scr: String = "ext") -> ParkedWindow { ParkedWindow(ws: ws, scr: scr, x: 0, y: 0, w: 100, h: 100, z: 1) }

    func testParkCutOffLeavesAVisibleWindowThatIsNotParked() {
        var s = WorkspaceState()
        s.hidden["1"] = entry(ws: 2)                     // its park never ran: it shows
        s.hidden["2"] = entry(ws: 2)                     // really parked
        s.hidden["3"] = entry(ws: 3)                     // park still on its way: leave it
        let dropped = s.dropShown(shows: { $0 == 1 || $0 == 3 }, moving: { $0 == 3 })
        expect(dropped == [1])
        expect(!s.isParked(1) && s.isParked(2) && s.isParked(3))
    }

    func testRestoreCutOffIsBroughtBack() {
        // Display "ext" shows workspace 2; window 5's restore to it was cut off by a restart and
        // kept as an entry on workspace 2. Window 6 is on hidden workspace 3.
        var s = WorkspaceState()
        s.active["ext"] = 2
        s.hidden["5"] = entry(ws: 2)
        s.hidden["6"] = entry(ws: 3)
        s.hidden["7"] = entry(ws: 1, scr: "builtin")     // builtin shows 1 (default): also stuck
        let stuck = s.takeOnShowingWorkspace { _ in true }
        expect(stuck.map(\.id) == [5, 7])
        expect(!s.isParked(5) && s.isParked(6) && !s.isParked(7))
    }

    func testIneligibleEntriesStay() {
        var s = WorkspaceState()
        s.hidden["5"] = entry(ws: 1)
        expect(s.takeOnShowingWorkspace { _ in false }.isEmpty && s.isParked(5))
    }
}

/// The log kept for diagnostics reports.
struct LogTests {
    func testBufferKeepsTheNewestLinesInOrder() {
        var b = LogBuffer(capacity: 3)
        for i in 1...2 { b.append("\(i)") }
        expect(b.all == ["1", "2"])
        for i in 3...7 { b.append("\(i)") }
        expect(b.all == ["5", "6", "7"] && b.count == 3)
    }

    func testLineFormatIsOneLine() {
        let l = LogFormat.line(time: "2026-11-26 08:00:00.000", level: "error", category: "workspaces", "a\nb")
        expect(l == "2026-11-26 08:00:00.000 error [workspaces] a ⏎ b")
        expect(LogFormat.line(time: "t", level: "info", category: "app", "x") == "t info  [app] x")
    }

    func testRotation() {
        expect(!LogFormat.shouldRotate(size: 1000, limit: 1 << 20))
        expect(LogFormat.shouldRotate(size: 1 << 20, limit: 1 << 20))
    }
}

/// Workspace 10 on the 0 key.
struct TenthWorkspaceTests {
    func testPlusCardOffersWorkspace10() {
        let c = OverviewModel.cards(active: 1, visible: [1], parked: (2...9).map { (UInt32($0), $0, 1) })
        expect(c.last?.isPlus == true && c.last?.workspace == 10)
    }

    func testZeroKeysAndHelp() {
        let r = AppConfiguration().resolvedBindings().bindings
        expect(r.first { $0.0 == .workspace10 }?.1 == Shortcut("alt+0"))
        expect(r.first { $0.0 == .moveToWorkspace10 }?.1 == Shortcut("alt+shift+0"))
        expect(r.first { $0.0 == .restoreAllWindows }?.1 == Shortcut("ctrl+alt+shift+0"))   // unchanged
        expect(!r.contains { $0.0 == .sendAllToWorkspace10 })
        expect(AppConfiguration().validate().isEmpty)                                         // no duplicate keys
    }

    func testCtrlOptionCmdABringsBackAll() {
        let r = AppConfiguration().resolvedBindings().bindings
        expect(r.first { $0.0 == .restoreAllWindowsAlt }?.1 == Shortcut("ctrl+alt+cmd+a"))
        expect(Action.restoreAllWindowsAlt.isRestoreAll && Action.restoreAllWindows.isRestoreAll && !Action.workspace1.isRestoreAll)
        expect(Action.restoreAllWindowsAlt.isWorkspaceAction && Action.restoreAllWindowsAlt.switchWorkspace == nil)
    }

    func testStateAcceptsWorkspace10() throws {
        var s = WorkspaceState()
        s.active["ext"] = 10
        s.hidden["1"] = ParkedWindow(ws: 10, scr: "ext", x: 0, y: 0, w: 100, h: 100, z: 1)
        let back = try JSONDecoder().decode(WorkspaceState.self, from: JSONEncoder().encode(s))
        expect(back.activeWorkspace("ext") == 10 && back.used(on: "ext") == [10])
    }
}

/// ⌃⇧ N: every window of the focused app onto workspace N.
struct AppGatherTests {
    let laptop = Display(id: 1, name: "Built-in", isBuiltin: true, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                         visibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 957), uuid: "L")
    let ext = Display(id: 2, name: "Ext", isBuiltin: false, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                      visibleFrame: CGRect(x: 1512, y: 25, width: 2560, height: 1415), uuid: "E")
    func parked(ws: Int, scr: String = "L") -> AppGather.Location {
        .parked(ParkedWindow(ws: ws, scr: scr, x: 10, y: 10, w: 800, h: 600, z: 1, px: 1500, py: 970))
    }

    func testVSCodeFromWorkspace2ComesToTheShowingWorkspace1() {
        // VS Code: focused window on workspace 1 (showing), another parked on workspace 2.
        let p = AppGather.plan(windows: [(1, .shown(on: laptop, frame: CGRect(x: 100, y: 100, width: 800, height: 600))),
                                         (2, parked(ws: 2))],
                               focused: 1, target: laptop, workspace: 1, active: 1)
        expect(p.park.isEmpty && p.relabel.isEmpty)
        expect(p.restore.map(\.id) == [2])                          // brought here; the focused one stays
        expect(p.restore.first?.frame == CGRect(x: 10, y: 35, width: 800, height: 600))
    }

    func testGatherOnAHiddenWorkspaceParksThemAll() {
        // ⌃⇧ 3 while workspace 1 shows: both go to workspace 3, the focused one on top.
        let p = AppGather.plan(windows: [(2, parked(ws: 2)),
                                         (1, .shown(on: laptop, frame: CGRect(x: 100, y: 100, width: 800, height: 600)))],
                               focused: 1, target: laptop, workspace: 3, active: 1)
        expect(p.restore.isEmpty)
        expect(p.park.map(\.id) == [1] && p.park[0].entry.ws == 3 && p.park[0].entry.z == 1)
        expect(p.relabel.map(\.id) == [2] && p.relabel[0].entry.ws == 3 && p.relabel[0].entry.z == 2)
        expect(p.relabel[0].entry.px == 1500)                       // still where it's parked
        expect(p.parkedOnN == 2)
    }

    func testWindowsOnAnotherDisplayComeOver() {
        let p = AppGather.plan(windows: [(1, .shown(on: laptop, frame: CGRect(x: 0, y: 25, width: 800, height: 600))),
                                         (2, .shown(on: ext, frame: CGRect(x: 1612, y: 125, width: 3000, height: 1200))),
                                         (3, parked(ws: 4, scr: "E"))],
                               focused: 1, target: laptop, workspace: 1, active: 1)
        expect(p.restore.map(\.id) == [2, 3])
        // Fitted to the laptop's screen.
        expect(p.restore.allSatisfy { laptop.visibleFrame.contains($0.frame) })
    }

    func testAlreadyThereIsLeftAlone() {
        let p = AppGather.plan(windows: [(1, .shown(on: laptop, frame: CGRect(x: 0, y: 25, width: 800, height: 600))),
                                         (2, parked(ws: 3))],
                               focused: 1, target: laptop, workspace: 3, active: 1)
        expect(p.relabel.isEmpty && p.park.map(\.id) == [1])
        let none = AppGather.plan(windows: [(1, .shown(on: laptop, frame: .zero))], focused: 1, target: laptop, workspace: 1, active: 1)
        expect(none.isEmpty)
    }

    func testKeys() {
        let r = AppConfiguration().resolvedBindings().bindings
        expect(r.first { $0.0 == .gatherApp1 }?.1 == Shortcut("ctrl+shift+1"))
        expect(r.first { $0.0 == .gatherApp10 }?.1 == Shortcut("ctrl+shift+0"))
        expect(Action.gatherApp7.gatherAppWorkspace == 7 && Action.gatherApp10.gatherAppWorkspace == 10)
        expect(Action.gatherApp1.switchWorkspace == nil && Action.gatherApp1.isWorkspaceAction)
        expect(AppConfiguration().validate().isEmpty)
    }
}

/// Clicking a visible VS Code window while another VS Code window is parked on workspace 2:
/// macOS first reports the parked one as focused. That must not switch to workspace 2.
struct FocusRevealTests {
    func testClickOnVisibleWindowOfTheSameAppDoesntSwitch() {
        // Focus moved on to the clicked window before the wait ended.
        expect(!FocusReveal.shouldReveal(stillFocused: false, stillParkedOrStranded: true, operationSince: false))
    }

    func testDockClickStillShowsTheParkedWindow() {
        // Nothing else took focus: the parked window really was asked for.
        expect(FocusReveal.shouldReveal(stillFocused: true, stillParkedOrStranded: true, operationSince: false))
    }

    func testNoRevealAfterAnotherOperationOrOnceShown() {
        expect(!FocusReveal.shouldReveal(stillFocused: true, stillParkedOrStranded: true, operationSince: true))
        expect(!FocusReveal.shouldReveal(stillFocused: true, stillParkedOrStranded: false, operationSince: false))
    }

    func testWaits() {
        expect(FocusReveal.delay(clickedVisibleWindowOfSameApp: true) > FocusReveal.delay(clickedVisibleWindowOfSameApp: false))
        expect(FocusReveal.wait >= 0.2 && FocusReveal.waitAfterClick <= 1.0)   // a Dock click still feels immediate enough
    }
}

/// The workspace state machine review: gaps found and fixed.
struct WorkspaceStateMachineTests {
    func entry(ws: Int, scr: String = "L", z: Int = 1, asleep: Bool? = nil) -> ParkedWindow {
        ParkedWindow(ws: ws, scr: scr, x: 10, y: 10, w: 800, h: 600, z: z, asleep: asleep)
    }

    // Gap 1: minimized windows and windows of hidden apps belong to the workspace being left.
    func testSleepersAreRecordedOnTheWorkspaceLeft() {
        let wins: [(id: UInt32, asleep: Bool, frame: CGRect)] = [
            (1, false, CGRect(x: 100, y: 100, width: 500, height: 400)),       // showing: parked the usual way
            (2, true, CGRect(x: 100, y: 100, width: 500, height: 400)),        // minimized on this display
            (3, true, CGRect(x: 3000, y: 100, width: 500, height: 400)),       // minimized on the other display
            (4, true, CGRect(x: 200, y: 200, width: 500, height: 400)),        // already parked
        ]
        let ids = Sleepers.leaving(windows: wins, display: 1, isParked: { $0 == 4 },
                                   displayOf: { $0.minX < 1512 ? 1 : 2 })
        expect(ids == [2])
    }

    func testWakingUp() {
        let e = entry(ws: 1, asleep: true)
        expect(Sleepers.wake(e, awake: false, active: 2) == .stay)              // still minimized
        expect(Sleepers.wake(e, awake: true, active: 2) == .showWorkspace(1))   // unminimized on workspace 2
        expect(Sleepers.wake(e, awake: true, active: 1) == .forget)             // its workspace shows
    }

    func testAsleepEntriesAreNeverTakenForShownWindows() {
        // Their frames are on screen by design (never moved).
        var s = WorkspaceState()
        s.hidden["2"] = entry(ws: 1, asleep: true)
        s.hidden["5"] = entry(ws: 1)
        expect(s.dropShown(shows: { _ in true }) == [5])
        expect(s.isParked(2))
    }

    func testAsleepFlagIsOptionalInTheFile() throws {
        let old = try JSONDecoder().decode(ParkedWindow.self, from: Data(#"{"ws":2,"scr":"L","x":0,"y":0,"w":1,"h":1,"z":1}"#.utf8))
        expect(old.asleep == nil && !old.isAsleep)
        let plain = String(data: try JSONEncoder().encode(entry(ws: 2)), encoding: .utf8)!
        expect(!plain.contains("asleep"))                                       // unchanged for Hammerspoon
        let sleepy = try JSONDecoder().decode(ParkedWindow.self, from: JSONEncoder().encode(entry(ws: 2, asleep: true)))
        expect(sleepy.isAsleep)
    }

    // Gap 2: entries on a display that isn't connected are brought back.
    func testEntriesOnMissingDisplaysAreTaken() {
        var s = WorkspaceState()
        s.hidden["1"] = entry(ws: 2, scr: "gone")
        s.hidden["2"] = entry(ws: 3, scr: "L")
        let taken = s.takeOnMissingDisplays(connected: ["L"])
        expect(taken.map(\.id) == [1] && !s.isParked(1) && s.isParked(2))
        expect(s.takeOnMissingDisplays(connected: ["L"]).isEmpty)
    }

    // Gap 3: ⌥⇧ N and an overview drag record the real frame, not a stale parked one.
    func testRecordedFrameIsTheLiveOne() {
        let parkedSpot = CGRect(x: 1500, y: 970, width: 800, height: 600)    // Monarch's stale copy
        let live = CGRect(x: 100, y: 100, width: 800, height: 600)
        expect(CurrentFrame.best(restoreTarget: nil, live: live, cached: parkedSpot) == live)
        let target = CGRect(x: 40, y: 60, width: 800, height: 600)
        expect(CurrentFrame.best(restoreTarget: target, live: parkedSpot, cached: parkedSpot) == target)
        expect(CurrentFrame.best(restoreTarget: nil, live: nil, cached: live) == live)
    }

    // Gaps 6 and 7: focus once, and never a window whose restore failed.
    func testFocusAtTheEndOfAnOperation() {
        expect(FinishFocus.step(window: 5, focusedEarly: nil, restoreFailed: false) == .focus)
        expect(FinishFocus.step(window: 5, focusedEarly: 5, restoreFailed: false) == .nothing)     // ⌃⇧ N used to focus twice
        expect(FinishFocus.step(window: 5, focusedEarly: nil, restoreFailed: true) == .topInstead) // off screen: not focused
        expect(FinishFocus.step(window: 5, focusedEarly: 9, restoreFailed: false) == .focus)
    }

    // Gap 4: the window sent last comes back on top (it used to tie at z 0).
    func testSentWindowGoesOnTop() {
        var s = WorkspaceState()
        s.hidden["1"] = entry(ws: 2, z: 1)
        s.hidden["2"] = entry(ws: 2, z: 2)
        for id in [7, 8] {                                                      // two ⌥⇧2 in a row
            s.makeRoom(1, onTopOf: 2, on: "L")
            s.hidden[String(id)] = entry(ws: 2, z: 1)
        }
        // Restored bottom to top: the last one restored is the top (and gets focus).
        expect(s.incoming(2, on: "L").map(\.id) == [2, 1, 7, 8])
    }

    // Gap 5: a click that started the operation doesn't count; one during it does.
    func testOnlyClicksDuringTheOperationAreRechecked() {
        expect(FocusReveal.clickCounts(secondsSinceClick: 0.1, secondsSinceOperationStart: 0.4))    // Dock click mid-switch
        expect(!FocusReveal.clickCounts(secondsSinceClick: 0.5, secondsSinceOperationStart: 0.4))   // the overview click that started it
        expect(!FocusReveal.clickCounts(secondsSinceClick: 2, secondsSinceOperationStart: 5))       // too long ago
        expect(!FocusReveal.recheckAfterOperation(clickedRecently: false))
        expect(FocusReveal.recheckLimit >= 2 && FocusReveal.recheckDelay * Double(FocusReveal.recheckLimit) <= 3)
    }

    // Gap 8: a switch fits restored windows to the display (it may have changed size).
    func testRestoreIsFittedToASmallerDisplay() {
        let f = Parking.fit(CGRect(x: 1800, y: 900, width: 2400, height: 1300), into: CGSize(width: 1512, height: 957))
        expect(f.maxX <= 1512 && f.maxY <= 957 && f.minX >= 0 && f.minY >= 0)
    }
}

/// Found by simulating the fixes on the real Mac.
struct SimulationFindingsTests {
    // ⌘H on TextEdit handed focus to VS Code, whose window was parked on workspace 2: Monarch
    // jumped to workspace 2. A hand-off isn't a request; a Dock click after it is.
    func testHidingAnAppIsAHandOffNotARequest() {
        expect(FocusReveal.isHandOff(secondsSinceAppGone: 0.05, secondsSinceClick: 30))     // ⌘H, no click
        expect(!FocusReveal.isHandOff(secondsSinceAppGone: 0.5, secondsSinceClick: 0.1))    // Dock click after it
        expect(!FocusReveal.isHandOff(secondsSinceAppGone: 5, secondsSinceClick: 30))       // long after: a real request
        // Decided after the 0.3 s wait; macOS reported the hide after the focus change.
        expect(FocusReveal.isHandOff(secondsSinceAppGone: 0.9, secondsSinceClick: 30, waited: 0.3))
    }

    // A switch 0.4 s after launch (a focus reveal) parked nothing: apps weren't all known yet.
    func testOperationsWaitForDiscovery() {
        let t = Discovery.settledAt(start: 100, otherApps: 20)
        expect(t > 100 + 0.15 + 20 * 0.02)                     // after the last app was asked
        expect(t < 100 + 3)                                    // but not long after
        expect(Discovery.settledAt(start: 0, otherApps: 40) > Discovery.settledAt(start: 0, otherApps: 5))
    }

    // A Dock click while a switch ran: the switch's own focus at the end took focus away from
    // the clicked app. The user's click wins.
    func testClickDuringAnOperationWinsOverItsFocus() {
        expect(FocusReveal.userClickedDuring(secondsSinceClick: 0.2, secondsSinceOperationStart: 0.4))
        expect(!FocusReveal.userClickedDuring(secondsSinceClick: 0.4, secondsSinceOperationStart: 0.4))   // the click that started it
        expect(!FocusReveal.userClickedDuring(secondsSinceClick: 0.37, secondsSinceOperationStart: 0.4))  // within 50 ms: its own
        expect(!FocusReveal.userClickedDuring(secondsSinceClick: 9, secondsSinceOperationStart: 0.4))     // before it
    }
}

/// The overview only lists used workspaces and the first free one: ⇧ + digit sends the
/// selected window to any workspace (3 when 1, 4 and the "+" for 2 show).
struct OverviewDigitTests {
    func testDigitKeyCodes() {
        let top = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        expect(top.map { OverviewModel.workspace(forKeyCode: $0) } == (1...10).map { Optional($0) })
        let pad = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]
        expect(pad.map { OverviewModel.workspace(forKeyCode: $0) } == (1...10).map { Optional($0) })
        expect(OverviewModel.workspace(forKeyCode: 0) == nil)      // A
        expect(OverviewModel.workspace(forKeyCode: 49) == nil)     // Space
    }

    func testShiftDigitSendsSelectedWindow() {
        expect(OverviewModel.digitAction(keyCode: 20, shift: true, carrying: false, windowSelected: true) == .send(3))
        expect(OverviewModel.digitAction(keyCode: 20, shift: false, carrying: true, windowSelected: true) == .send(3))
        expect(OverviewModel.digitAction(keyCode: 29, shift: true, carrying: false, windowSelected: true) == .send(10))
        // Plain digit, or no window selected (a card): show that workspace.
        expect(OverviewModel.digitAction(keyCode: 20, shift: false, carrying: false, windowSelected: true) == .show(3))
        expect(OverviewModel.digitAction(keyCode: 20, shift: true, carrying: false, windowSelected: false) == .show(3))
        expect(OverviewModel.digitAction(keyCode: 0, shift: true, carrying: false, windowSelected: true) == nil)
    }
}

/// WhatsApp opened from a notification on the MacBook: its focus came before Monarch knew the
/// window, so Slack stayed "last used" there, and moving the mouse over raised Slack over it.
struct NewWindowFocusTests {
    func cand(_ id: UInt32, _ f: CGRect, pid: Int32) -> FocusCandidate {
        FocusCandidate(id: id, pid: pid, frame: f, isMinimized: false, appHidden: false)
    }

    func testNeverUsedFrontWindowBeatsLastUsed() {
        let onMac = CGRect(x: 600, y: 1500, width: 700, height: 500), onLG = CGRect(x: 100, y: 100, width: 800, height: 600)
        let slack: UInt32 = 3, whatsapp: UInt32 = 4, code: UInt32 = 1
        let w = [code: cand(code, onLG, pid: 10), slack: cand(slack, onMac, pid: 20), whatsapp: cand(whatsapp, onMac, pid: 30)]
        var h = FocusHistory()
        h.record(window: slack, display: 2)
        h.record(window: code, display: 1)
        // WhatsApp is in front on the MacBook and was never recorded: it gets focus, Slack stays behind.
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: code, windows: w, history: h,
                                          zOrder: { [code, whatsapp, slack] }) == whatsapp)
        // Once WhatsApp is recorded as used, history decides as before (Slack last used there).
        h.record(window: whatsapp, display: 2); h.record(window: slack, display: 2); h.record(window: code, display: 1)
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: code, windows: w, history: h,
                                          zOrder: { [code, whatsapp, slack] }) == slack)
        // Slack in front and last used: Slack (no change).
        expect(FocusLogic.windowForScreen(mac, displays: [lg, mac], focused: code, windows: w, history: h,
                                          zOrder: { [slack, whatsapp] }) == slack)
    }
}
