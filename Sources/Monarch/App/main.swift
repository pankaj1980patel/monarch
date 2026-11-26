import AppKit
import ServiceManagement

/// The launch agent that starts Monarch at login and restarts it if it crashes
/// (Contents/Library/LaunchAgents in the bundle, registered with SMAppService).
let monarchAgentLabel = "dev.monarch.Monarch.agent"
/// Asks a running Monarch to quit so the agent-managed copy can take over.
let monarchHandoverNote = Notification.Name("dev.monarch.Monarch.handover")

// `Monarch --login-status`: prints whether the login agent is registered (for diagnostics).
if CommandLine.arguments.contains("--login-status") {
    let names = [0: "notRegistered", 1: "enabled", 2: "requiresApproval", 3: "notFound"]
    let st = SMAppService.agent(plistName: monarchAgentLabel + ".plist").status
    print("login agent: \(names[st.rawValue] ?? "\(st.rawValue)")")
    print("old login item: \(names[SMAppService.mainApp.status.rawValue] ?? "?")")
    exit(0)
}
// `Monarch --check-config`: validates config.json the way ⌃⌥⇧ R does; exit 1 if it has problems.
if CommandLine.arguments.contains("--check-config") {
    let (c, err) = ConfigurationStore.load()
    let problems = err.map { [$0] } ?? c.validate()
    print(problems.isEmpty ? "config.json OK" : problems.map { "✕ " + $0 }.joined(separator: "\n"))
    exit(problems.isEmpty ? 0 : 1)
}
// `Monarch --unregister-login`: removes the login agent (diagnostics / repair).
if CommandLine.arguments.contains("--unregister-login") {
    do { try SMAppService.agent(plistName: monarchAgentLabel + ".plist").unregister(); print("unregistered") }
    catch { print("unregister failed: \(error)") }
    exit(0)
}
// `Monarch --render-overview-demo <file.png>`: the README screenshot, from sample data.
if let i = CommandLine.arguments.firstIndex(of: "--render-overview-demo"), i + 1 < CommandLine.arguments.count {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let ok = MainActor.assumeIsolated { OverviewDemo.render(to: url) }
    print(ok ? "wrote \(url.path)" : "render failed")
    exit(ok ? 0 : 1)
}
// `Monarch --register-login`: (re-)registers the login agent and prints the result.
// launchd ties the agent to the bundle version it was registered with, so after a rebuild
// (new CFBundleVersion) it must be unregistered and registered again, or it won't start.
if CommandLine.arguments.contains("--register-login") {
    let agent = SMAppService.agent(plistName: monarchAgentLabel + ".plist")
    if agent.status == .enabled || agent.status == .requiresApproval { try? agent.unregister() }
    do { try agent.register(); print("registered, status \(agent.status.rawValue)") }
    catch { print("register failed: \(error)") }
    exit(0)
}

// One Monarch at a time. A copy started by the agent takes over from a hand-started one
// (so crash restarts stay in effect); any other second copy just leaves.
do {
    let me = ProcessInfo.processInfo.processIdentifier
    let fromAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == monarchAgentLabel
    func others() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.monarch.Monarch")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
    }
    if !others().isEmpty {
        guard fromAgent else { exit(0) }
        DistributedNotificationCenter.default().postNotificationName(monarchHandoverNote, object: nil, userInfo: nil, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(3)
        while !others().isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        // The other copy didn't quit: exit with a failure, so launchd tries again shortly
        // (a clean exit would leave no agent-managed copy, and no crash restarts).
        if !others().isEmpty { exit(75) }                // EX_TEMPFAIL
    }
}

// `kill` / `pkill` (SIGTERM): quit normally, so ⌘Tab and Hammerspoon's keys are handed back
// and launchd sees a clean exit (no restart).
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
termSource.resume()
// SIGHUP: quit to be restarted (scripts/build-app.sh). Like SIGTERM, but windows on hidden
// workspaces stay parked: the next copy loads them from workspaces.json.
signal(SIGHUP, SIG_IGN)
let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hupSource.setEventHandler {
    MainActor.assumeIsolated {
        (NSApp.delegate as? AppDelegate)?.restarting = true
        NSApp.terminate(nil)
    }
}
hupSource.resume()

// Menu bar agent: no Dock icon, no main window (LSUIElement is also set in Info.plist).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
