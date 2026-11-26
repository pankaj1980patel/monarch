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

    func testBuildScriptRestartsWithSIGHUP() throws {
        let script = try source("scripts/build-app.sh")
        let kills = script.split(separator: "\n").filter { $0.contains("pkill") }
        expect(!kills.isEmpty && kills.allSatisfy { $0.contains("-HUP") })
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
        expect(main.contains("makeSignalSource(signal: SIGHUP"))
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
    func testFingersLiftingOneByOneDontScroll() {
        var g = ScrollGuard()
        g.frame(locked: true, contacts: 3, now: 0.0)
        // The gesture ends as fingers lift; two are still moving: macOS would scroll.
        g.frame(locked: false, contacts: 2, now: 0.1)
        expect(g.shouldDrop(phase: 1, momentum: 0, now: 0.1))
        expect(g.shouldDrop(phase: 2, momentum: 0, now: 0.15))
        g.frame(locked: false, contacts: 0, now: 0.2)
        expect(g.shouldDrop(phase: 4, momentum: 0, now: 0.3))         // within the tail
        expect(g.shouldDrop(phase: 0, momentum: 2, now: 0.9))         // coasting
        expect(g.shouldDrop(phase: 0, momentum: 3, now: 1.2))
    }

    func testANewScrollAfterwardsWorks() {
        var g = ScrollGuard()
        g.frame(locked: true, contacts: 3, now: 0)
        g.frame(locked: false, contacts: 0, now: 0.2)
        expect(!g.shouldDrop(phase: 1, momentum: 0, now: 1.0))        // a new two-finger scroll begins
        expect(!g.shouldDrop(phase: 2, momentum: 0, now: 1.05))
        expect(!g.shouldDrop(phase: 0, momentum: 2, now: 1.5))        // and its own coasting is kept
    }

    func testThumbAndFingerLeftDownDontScroll() {
        var g = ScrollGuard()
        g.frame(locked: true, contacts: 4, now: 0)
        g.frame(locked: false, contacts: 2, now: 0.1)                 // gesture over, thumb + one finger down
        g.frame(locked: false, contacts: 2, now: 0.5)
        expect(g.shouldDrop(phase: 2, momentum: 0, now: 0.5))
    }

    func testOrdinaryScrollingIsNeverTouched() {
        var g = ScrollGuard()
        g.frame(locked: false, contacts: 2, now: 0)                   // two-finger scroll (or thumb + two)
        g.frame(locked: false, contacts: 3, now: 0.05)
        expect(!g.shouldDrop(phase: 1, momentum: 0, now: 0.05))
        g.frame(locked: false, contacts: 0, now: 0.2)
        expect(!g.shouldDrop(phase: 0, momentum: 2, now: 0.3))        // its coasting too
        expect(!g.shouldDrop(phase: 0, momentum: 0, now: 0.3))        // wheel mouse
    }

    func testLostLiftFrameNeverBlocksForever() {
        var g = ScrollGuard()
        g.frame(locked: true, contacts: 3, now: 0)                    // then no more frames
        expect(g.shouldDrop(phase: 2, momentum: 0, now: 0.2))
        expect(!g.shouldDrop(phase: 0, momentum: 0, now: 5))          // wheel mouse, long after
        expect(!g.shouldDrop(phase: 1, momentum: 0, now: 5.1))
    }

    func testWheelMouseAfterASwipe() {
        var g = ScrollGuard()
        g.frame(locked: true, contacts: 3, now: 0)
        g.frame(locked: false, contacts: 0, now: 0.1)
        expect(!g.shouldDrop(phase: 0, momentum: 0, now: 0.6))        // after the tail: a mouse wheel scrolls
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
