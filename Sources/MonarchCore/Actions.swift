/// Every action Monarch can bind to a shortcut. Raw values are the keys used in config.json.
public enum Action: String, CaseIterable, Sendable, Codable {
    // Snapping (⌃⌥)
    case snapLeft = "snap.left"            // ½ → ⅓ → ⅔ on repeat
    case snapRight = "snap.right"
    case snapTop = "snap.top"
    case snapBottom = "snap.bottom"
    case maximize = "snap.maximize"
    case center = "snap.center"
    case topLeft = "snap.topLeft"
    case topRight = "snap.topRight"
    case bottomLeft = "snap.bottomLeft"
    case bottomRight = "snap.bottomRight"
    case leftThird = "snap.leftThird"
    case centerThird = "snap.centerThird"
    case rightThird = "snap.rightThird"
    case leftTwoThirds = "snap.leftTwoThirds"
    case rightTwoThirds = "snap.rightTwoThirds"
    case undo = "snap.undo"
    // Screens
    case moveScreenWest = "screen.moveWest"
    case moveScreenEast = "screen.moveEast"
    case moveScreenNextMaximize = "screen.moveNextMaximize"
    case fillToggle = "window.fillToggle"
    // Auto focus
    case toggleCrossScreenFocus = "focus.toggleCrossScreen"
    case toggleSameAppHover = "focus.toggleSameAppHover"
    case focusOtherScreen = "focus.otherScreen"
    case focusWest = "focus.west"
    case focusEast = "focus.east"
    case focusNorth = "focus.north"
    case focusSouth = "focus.south"

    // Arrange the top N windows of the screen under the mouse (0 = all)
    case arrangeAll = "arrange.all"
    case arrange1 = "arrange.1", arrange2 = "arrange.2", arrange3 = "arrange.3"
    case arrange4 = "arrange.4", arrange5 = "arrange.5", arrange6 = "arrange.6"
    case arrange7 = "arrange.7", arrange8 = "arrange.8", arrange9 = "arrange.9"

    // ⌘Tab switcher
    case switcherNext = "switcher.next"
    case switcherPrevious = "switcher.previous"
    case switcherWorkspaceNext = "switcher.workspaceNext"
    case switcherWorkspacePrevious = "switcher.workspacePrevious"

    public var isSwitcherAction: Bool { rawValue.hasPrefix("switcher.") }

    // Workspaces: ⌥ N switches the screen under the mouse, ⌥⇧ N sends the focused window
    case workspace1 = "workspace.1", workspace2 = "workspace.2", workspace3 = "workspace.3"
    case workspace4 = "workspace.4", workspace5 = "workspace.5", workspace6 = "workspace.6"
    case workspace7 = "workspace.7", workspace8 = "workspace.8", workspace9 = "workspace.9"
    case moveToWorkspace1 = "workspace.move.1", moveToWorkspace2 = "workspace.move.2", moveToWorkspace3 = "workspace.move.3"
    case moveToWorkspace4 = "workspace.move.4", moveToWorkspace5 = "workspace.move.5", moveToWorkspace6 = "workspace.move.6"
    case moveToWorkspace7 = "workspace.move.7", moveToWorkspace8 = "workspace.move.8", moveToWorkspace9 = "workspace.move.9"
    // ⌃⌥⇧ N: sends every window showing on the screen under the mouse to workspace N
    case sendAllToWorkspace1 = "workspace.sendAll.1", sendAllToWorkspace2 = "workspace.sendAll.2", sendAllToWorkspace3 = "workspace.sendAll.3"
    case sendAllToWorkspace4 = "workspace.sendAll.4", sendAllToWorkspace5 = "workspace.sendAll.5", sendAllToWorkspace6 = "workspace.sendAll.6"
    case sendAllToWorkspace7 = "workspace.sendAll.7", sendAllToWorkspace8 = "workspace.sendAll.8", sendAllToWorkspace9 = "workspace.sendAll.9"
    case restoreAllWindows = "workspace.restoreAll"

    public var isWorkspaceAction: Bool { rawValue.hasPrefix("workspace.") }

    // Overview (custom Mission Control)
    case toggleOverview = "overview.toggle"

    // Helpers
    case showHelp = "help.show"                  // the shortcut sheet
    case reloadConfig = "config.reload"
    case gestureStatus = "gestures.status"       // gesture settings, Dock state and recent swipes
    /// ⌥ N: the workspace to switch to.
    public var switchWorkspace: Int? {
        rawValue.hasPrefix("workspace.") ? Int(rawValue.dropFirst(10)) : nil
    }
    /// ⌥⇧ N: the workspace to send the focused window to.
    public var moveWorkspace: Int? { rawValue.hasPrefix("workspace.move.") ? Int(rawValue.dropFirst(15)) : nil }
    /// ⌃⌥⇧ N: the workspace to send every window on the screen under the mouse to.
    public var sendAllWorkspace: Int? { rawValue.hasPrefix("workspace.sendAll.") ? Int(rawValue.dropFirst(18)) : nil }

    /// For arrange actions: how many windows (0 = all). Nil for every other action.
    public var arrangeCount: Int? {
        guard rawValue.hasPrefix("arrange.") else { return nil }
        return self == .arrangeAll ? 0 : Int(rawValue.dropFirst("arrange.".count))
    }

    /// Handled by the auto-focus feature rather than snapping.
    public var isFocusAction: Bool { rawValue.hasPrefix("focus.") }

    /// Shortcuts matching the Hammerspoon setup this replaces.
    public var defaultShortcut: String {
        switch self {
        case .snapLeft: "ctrl+alt+left"
        case .snapRight: "ctrl+alt+right"
        case .snapTop: "ctrl+alt+up"
        case .snapBottom: "ctrl+alt+down"
        case .maximize: "ctrl+alt+return"
        case .center: "ctrl+alt+c"
        case .topLeft: "ctrl+alt+u"
        case .topRight: "ctrl+alt+i"
        case .bottomLeft: "ctrl+alt+j"
        case .bottomRight: "ctrl+alt+k"
        case .leftThird: "ctrl+alt+d"
        case .centerThird: "ctrl+alt+f"
        case .rightThird: "ctrl+alt+g"
        case .leftTwoThirds: "ctrl+alt+e"
        case .rightTwoThirds: "ctrl+alt+t"
        case .undo: "ctrl+alt+delete"
        case .moveScreenWest: "ctrl+alt+cmd+left"
        case .moveScreenEast: "ctrl+alt+cmd+right"
        case .moveScreenNextMaximize: "ctrl+alt+cmd+return"
        case .fillToggle: "ctrl+cmd+f"
        case .toggleCrossScreenFocus: "ctrl+alt+m"
        case .toggleSameAppHover: "ctrl+alt+h"
        case .focusOtherScreen: "ctrl+alt+n"
        case .focusWest: "ctrl+alt+shift+left"
        case .focusEast: "ctrl+alt+shift+right"
        case .focusNorth: "ctrl+alt+shift+up"
        case .focusSouth: "ctrl+alt+shift+down"
        case .workspace1, .workspace2, .workspace3, .workspace4, .workspace5,
             .workspace6, .workspace7, .workspace8, .workspace9:
            "alt+" + rawValue.dropFirst(10)
        case .moveToWorkspace1, .moveToWorkspace2, .moveToWorkspace3, .moveToWorkspace4, .moveToWorkspace5,
             .moveToWorkspace6, .moveToWorkspace7, .moveToWorkspace8, .moveToWorkspace9:
            "alt+shift+" + rawValue.dropFirst(15)
        case .sendAllToWorkspace1, .sendAllToWorkspace2, .sendAllToWorkspace3, .sendAllToWorkspace4, .sendAllToWorkspace5,
             .sendAllToWorkspace6, .sendAllToWorkspace7, .sendAllToWorkspace8, .sendAllToWorkspace9:
            "ctrl+alt+shift+" + rawValue.dropFirst(18)
        case .restoreAllWindows: "ctrl+alt+shift+0"
        case .toggleOverview: "ctrl+alt+space"
        case .showHelp: "ctrl+alt+/"
        case .reloadConfig: "ctrl+alt+shift+r"
        case .gestureStatus: "ctrl+alt+shift+g"
        case .switcherNext: "cmd+tab"
        case .switcherPrevious: "cmd+shift+tab"
        case .switcherWorkspaceNext: "cmd+`"
        case .switcherWorkspacePrevious: "cmd+shift+`"
        case .arrangeAll: "ctrl+alt+cmd+0"
        case .arrange1, .arrange2, .arrange3, .arrange4, .arrange5,
             .arrange6, .arrange7, .arrange8, .arrange9:
            "ctrl+alt+cmd+" + rawValue.dropFirst("arrange.".count)
        }
    }
}

/// What a snapping action does to the focused window.
public enum SnapPlan: Sendable, Equatable {
    case unit(UnitRect)
    case cycle(key: String, [UnitRect])
}

public enum SnapLayouts {
    public static func plan(for action: Action) -> SnapPlan? {
        switch action {
        case .snapLeft: .cycle(key: "left", [UnitRect(0, 0, 0.5, 1), UnitRect(0, 0, 1.0 / 3, 1), UnitRect(0, 0, 2.0 / 3, 1)])
        case .snapRight: .cycle(key: "right", [UnitRect(0.5, 0, 0.5, 1), UnitRect(2.0 / 3, 0, 1.0 / 3, 1), UnitRect(1.0 / 3, 0, 2.0 / 3, 1)])
        case .snapTop: .unit(UnitRect(0, 0, 1, 0.5))
        case .snapBottom: .unit(UnitRect(0, 0.5, 1, 0.5))
        case .maximize: .unit(UnitRect(0, 0, 1, 1))
        case .center: .unit(UnitRect(0.15, 0.15, 0.7, 0.7))
        case .topLeft: .unit(UnitRect(0, 0, 0.5, 0.5))
        case .topRight: .unit(UnitRect(0.5, 0, 0.5, 0.5))
        case .bottomLeft: .unit(UnitRect(0, 0.5, 0.5, 0.5))
        case .bottomRight: .unit(UnitRect(0.5, 0.5, 0.5, 0.5))
        case .leftThird: .unit(UnitRect(0, 0, 1.0 / 3, 1))
        case .centerThird: .unit(UnitRect(1.0 / 3, 0, 1.0 / 3, 1))
        case .rightThird: .unit(UnitRect(2.0 / 3, 0, 1.0 / 3, 1))
        case .leftTwoThirds: .unit(UnitRect(0, 0, 2.0 / 3, 1))
        case .rightTwoThirds: .unit(UnitRect(1.0 / 3, 0, 2.0 / 3, 1))
        default: nil
        }
    }
}
