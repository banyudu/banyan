import Foundation
import Testing
@testable import BanyanCore

/// Opt-in subprocess benchmark. The clock advances virtually; tmux operations,
/// process-table reads and classifications run for real on a private socket.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_SUPERVISOR_BENCH_DIR"] != nil))
func supervisorSevenSessionSubprocessBenchmark() throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BANYAN_SUPERVISOR_BENCH_DIR"]!)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let backend = BenchmarkSupervisorBackend(socketName: "banyan-supervisor-bench-\(UUID().uuidString)")
    let names = (0..<7).map { "fixture-\($0)" }
    defer { for name in names { backend.tmux.killSession(named: name) } }
    for name in names {
        try backend.tmux.ensureSession(named: name, cwd: root.path,
                                       command: "printf '\\033[999;1HEsc to interrupt'; exec /bin/sleep 300")
    }
    let inputs = names.map {
        SessionStatusObservationInput(id: $0, tmuxSessionName: $0, command: "codex", status: .executing, isAwaitingAttach: false)
    }
    var counts: [[String: Any]] = []
    for scenario in ["quiet-active", "quiet-hidden", "output-active"] {
        let base: TimeInterval = scenario == "quiet-hidden" ? 30 : 2
        for legacy in [true, false] {
            let mode = legacy ? "before" : "after"
            let directory = root.appendingPathComponent("\(scenario)/\(mode)")
            let store = PerformanceEventStore(databaseURL: directory.appendingPathComponent("Banyan/state.sqlite"))
            let cache = SupervisorInspectionCache()
            var states: [String: SessionSupervisorObservationState] = [:]
            var events: [PerformanceEvent] = []
            var snapshots = 0
            var observed = 0
            var second: TimeInterval = 0
            backend.resetCounts()
            while second < 180 {
                let now = Date(timeIntervalSince1970: 1000 + second)
                // Synthetic whole-second activity, with real pane capture and
                // process inspection. Quiet runs stay unchanged; output runs
                // invalidate every pane each tick, like a streaming agent TUI.
                backend.activityAt = Date(timeIntervalSince1970: scenario == "output-active" ? 1000 + second : 900)
                let start = DispatchTime.now()
                let panes = backend.primaryPaneSnapshots(named: Set(names))
                let due = inputs.filter { legacy || states[$0.id]?.isDue(pane: panes[$0.tmuxSessionName], at: now) != false }
                if !due.isEmpty {
                    snapshots += 1
                    let collector = BenchmarkDurationCollector()
                    let results = SessionStatusSynchronizer(backend: backend, processTable: .snapshot(), cache: cache)
                        .observe(due, paneSnapshots: panes) { _, duration in collector.append(duration) }
                    #expect(results.count == 7)
                    #expect(results.allSatisfy { $0.status == .executing })
                    observed += results.count
                    events += collector.values.map { PerformanceEvent(name: "supervisor.session", durationMS: $0) }
                    for result in results {
                        let revision = states[result.id]?.revision ?? 0
                        states[result.id, default: .init()].record(result, pane: panes[result.id], startedRevision: revision,
                                                                 at: now, baseInterval: base, isSelectedAttached: false)
                    }
                }
                events.append(PerformanceEvent(name: "supervisor.tick", durationMS: PerformanceTelemetry.elapsedMS(since: start)))
                let interval = legacy ? base : states.values.map {
                    $0.nextProbeInterval(baseInterval: base, status: .executing, isSelectedAttached: false, at: now)
                }.min() ?? base
                second += interval
            }
            // Keep every sample here. Production telemetry intentionally keeps
            // only slow supervisor events, so its percentiles are not a census.
            store.record(events)
            let report = store.report(since: .distantPast)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"))
            counts.append([
                "scenario": scenario, "mode": mode, "virtual_seconds": 180,
                "scheduled_tick_wakeups": backend.batches,
                "list_panes_subprocesses": backend.batches,
                "capture_pane_subprocesses": backend.captures,
                "process_snapshots": snapshots, "session_observations": observed,
                "single_pane_lookups": backend.singles
            ])
        }
    }
    let data = try JSONSerialization.data(withJSONObject: counts, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("counts.json"))
}

private final class BenchmarkSupervisorBackend: AgentSupervisorBackend, @unchecked Sendable {
    let tmux: TmuxBackend
    var activityAt = Date(timeIntervalSince1970: 900)
    private let lock = NSLock()
    private var captureCount = 0
    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var batches = 0
    var singles = 0

    init(socketName: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["SHELL"] = "/bin/sh"
        environment.removeValue(forKey: "TMUX")
        tmux = TmuxBackend(environment: environment, workingDirectory: "/tmp", socketName: socketName)
    }

    func resetCounts() { captureCount = 0; batches = 0; singles = 0 }
    func hasSession(named name: String) -> Bool { tmux.hasSession(named: name) }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        singles += 1
        return tmux.primaryPaneSnapshot(named: name).map(agentPane)
    }
    func primaryPaneSnapshots(named names: Set<String>) -> [String: TmuxPaneSnapshot] {
        batches += 1
        return tmux.primaryPaneSnapshots(named: names).mapValues(agentPane)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        lock.lock(); captureCount += 1; lock.unlock()
        return tmux.captureVisibleText(paneID: paneID, lineLimit: lineLimit)
    }
    private func agentPane(_ pane: TmuxPaneSnapshot) -> TmuxPaneSnapshot {
        // No real coding agent is launched. The sleep-backed pane exposes
        // synthetic agent metadata and executing text for classification.
        TmuxPaneSnapshot(paneID: pane.paneID, rootPID: pane.rootPID, currentCommand: "codex",
                         currentPath: pane.currentPath, isDead: pane.isDead, isInMode: pane.isInMode,
                         lastActivityAt: activityAt, width: pane.width, height: pane.height)
    }
}

private final class BenchmarkDurationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Double] = []
    func append(_ duration: Double) { lock.lock(); durations.append(duration); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return durations }
}
