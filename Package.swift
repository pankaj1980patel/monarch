// swift-tools-version: 6.0
import PackageDescription

let release: [SwiftSetting] = [
    .unsafeFlags(["-Osize", "-wmo"], .when(configuration: .release)),
]

let package = Package(
    name: "Monarch",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Monarch", targets: ["Monarch"]),
    ],
    targets: [
        // Pure logic: geometry, layouts, undo history, config, stats. No AppKit, fully testable.
        .target(name: "MonarchCore", swiftSettings: release),
        // The menu bar app: Accessibility, Carbon hotkeys, displays, UI.
        .executableTarget(
            name: "Monarch",
            dependencies: ["MonarchCore"],
            swiftSettings: release,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Unit checks for MonarchCore. A plain executable: the Command Line Tools' Swift Testing
        // can't load tests from this compiler and XCTest needs Xcode. Run: swift run MonarchChecks
        .executableTarget(name: "MonarchChecks", dependencies: ["MonarchCore"], path: "Tests/MonarchChecks"),
    ]
)
