import AppKit
import BanyanCore
import Darwin
import Foundation
import Testing
@testable import Banyan

/// Run alone: this exercises real SessionStore timers/process events, without
/// starting an app control server or using the live app's tmux socket/home.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_SUPERVISOR_RUNTIME_DIR"] != nil))
func supervisorSevenHiddenSessionRuntimeFixture() async throws {
    _ = NSApplication.shared
    try #require(!NSApp.isActive && NSApp.windows.allSatisfy { !$0.isVisible }, "Run this fixture alone in a windowless test process")
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_SUPERVISOR_RUNTIME_DIR"]!)
    let home = root.appendingPathComponent("home")
    let data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    environment["SHELL"] = "/bin/sh"
    environment["BANYAN_FIXTURE_DATA_HOME"] = data.path
    environment.removeValue(forKey: "TMUX")
    let host = HostRuntimeContext(environment: environment, homeDirectory: home, currentDirectory: home.path)
    let backend = TmuxBackend(environment: environment, workingDirectory: home.path,
                              socketName: "supervisor-runtime-\(UUID().uuidString)")
    let script = home.appendingPathComponent("codex")
    // A disposable shell agent: actual process/pane metadata identifies it by
    // its script name. No authentication, model API, or real agent is involved.
    try """
    #!/bin/sh
    stty -echo
    printf '\\033[?1049h'
    if [ "$1" = silent ]; then
      printf '\\033[2J\\033[999;1HDone.'
      /bin/cat "$2" >/dev/null
    else
      printf '\\033[2J\\033[999;1HEsc to interrupt'
    fi
    while IFS= read -r command; do
      case "$command" in
        attention) printf '\\033[2J\\033[999;1HCan I edit these files?' ;;
        executing) printf '\\033[2J\\033[999;1HEsc to interrupt' ;;
      esac
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    let fifo = home.appendingPathComponent("completion.fifo")
    try #require(mkfifo(fifo.path, 0o600) == 0)
    let persistence = SessionPersistence(databaseURL: data.appendingPathComponent("Banyan/state.sqlite"),
                                         legacyJSONURL: data.appendingPathComponent("sessions.json"))
    let telemetry = PerformanceTelemetry(store: PerformanceEventStore(databaseURL: PerformanceEventStore.defaultDatabaseURL(host: host)))
    let processes = RuntimeFixtureProcesses()
    let daemon = FakePuckDaemon()
    let preferencesName = "supervisor-runtime-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: preferencesName))
    defer { preferences.removePersistentDomain(forName: preferencesName) }
    let store = SessionStore(persistence: persistence, tmuxBackend: backend, sessionBackend: backend,
                             processTable: processes, historyBackend: DefaultSessionHistoryBackend(homeDirectory: home),
                             detector: AgentStateDetector(rules: []), host: host, telemetry: telemetry,
                             attentionNotifier: AttentionNotifier(), puckDaemon: daemon, freezePreferences: preferences)
    let names = (0..<7).map { "banyan-fixture-\($0)" }
    defer {
        store.stopPuckObservation()
        for session in store.sessions { session.status = .closed; session.terminate(markClosed: true) }
        for name in names { backend.killSession(named: name) }
        telemetry.flushPendingEventsAndWait()
    }
    var snapshots: [SessionSnapshot] = []
    for index in 0..<7 {
        let command = "/bin/sh \(AgentLaunchCommand.shellQuote(script.path))" + (index == 1 ? " silent \(AgentLaunchCommand.shellQuote(fifo.path))" : "")
        try backend.ensureSession(named: names[index], cwd: home.path, command: command)
        snapshots.append(.init(id: "fixture-\(index)", tmuxSessionName: names[index], title: "Fixture \(index)",
                               reportedTitle: nil, cwd: home.path, command: command, status: .executing, tone: .blue,
                               createdAt: Date(), updatedAt: Date()))
    }
    persistence.save(snapshots)
    store.loadPersistedSessionsIfNeeded()
    store.startSupervisor()
    try await runtimeFixtureWait(seconds: 10) {
        store.sessions.count == 7 && store.sessions.allSatisfy { $0.detectedAgentProvider == .codex && $0.status == .executing }
    }
    #expect(store.terminalSessions.allSatisfy { $0.loadedTerminalView == nil })
    // Real hidden cadence (30s): warm through the three stable observations.
    // Swift Testing does not run NSApplication.run(). Service this private
    // process's Foundation timers explicitly, as the real app run loop does.
    for _ in 0..<105 {
        serviceRuntimeRunLoop()
        try await Task.sleep(for: .seconds(1))
    }
    serviceRuntimeRunLoop()
    #expect(processes.count >= 4)
    #expect(processes.count < 10)
    FileHandle.standardError.write(Data("Supervisor fixture warmup: process_snapshots=\(processes.count)\n".utf8))

    var measurements: [String: Double] = [:]
    func record(_ name: String, _ value: Double) throws {
        measurements[name] = value
        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("latency.json"))
    }
    func send(_ command: String, index: Int) throws {
        let pane = try #require(backend.primaryPaneSnapshot(named: names[index]))
        try backend.sendLiteral(paneID: pane.paneID, text: command)
        try backend.sendKeys(paneID: pane.paneID, keys: [.enter])
    }
    func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    let hidden = try #require(store.terminalSessions.first { $0.id == "fixture-0" })
    let hiddenStart = ContinuousClock.now
    try send("attention", index: 0) // Bypasses API invalidation: no PTY callback.
    try await runtimeFixtureWait(seconds: 42) { hidden.status == .asking }
    try record("hidden_unattached_attention_s", elapsed(hiddenStart))

    let silent = try #require(store.terminalSessions.first { $0.id == "fixture-1" })
    let exitStart = ContinuousClock.now
    let writer = try FileHandle(forWritingTo: fifo)
    try writer.write(contentsOf: Data("finished\n".utf8))
    try writer.close() // EOF ends only this fixture's cat child, without output.
    try await runtimeFixtureWait(seconds: 6) { silent.status == .needInput }
    try record("hidden_silent_completion_s", elapsed(exitStart))

    let selected = try #require(store.terminalSessions.first { $0.id == "fixture-2" })
    store.selectedSessionID = selected.id
    selected.terminalView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    selected.start()
    try await runtimeFixtureWait(seconds: 10) { selected.loadedTerminalView?.process.running == true }
    let attachedStart = ContinuousClock.now
    try send("attention", index: 2)
    try await runtimeFixtureWait(seconds: 6) { selected.status == .asking }
    try record("selected_attached_attention_s", elapsed(attachedStart))

    // Recreate the cache-eviction condition, rather than relying only on a
    // session that was never attached. The pane survives; the PTY disappears.
    try send("executing", index: 2)
    try await runtimeFixtureWait(seconds: 6) { selected.status == .executing }
    selected.unloadTerminalView()
    try #require(selected.loadedTerminalView == nil)
    let evictedStart = ContinuousClock.now
    try send("attention", index: 2)
    try await runtimeFixtureWait(seconds: 42) { selected.status == .asking }
    try record("hidden_evicted_attention_s", elapsed(evictedStart))
    try record("process_snapshots", Double(processes.count))
}

@MainActor
private func runtimeFixtureWait(seconds: Int, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        serviceRuntimeRunLoop()
        try #require(ContinuousClock.now < deadline, "Private supervisor fixture missed its latency bound")
        try await Task.sleep(for: .milliseconds(100))
    }
}

@MainActor
private func serviceRuntimeRunLoop() {
    _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
}

private final class RuntimeFixtureProcesses: ProcessTableProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return snapshots }
    func snapshot() -> ProcessTable {
        lock.lock(); snapshots += 1; lock.unlock()
        return .snapshot()
    }
}
