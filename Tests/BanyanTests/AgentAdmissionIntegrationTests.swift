import AppKit
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

/// Opt-in native runtime checks. Every pane belongs to a UUID socket and the
/// fixture's database/home. Cleanup names only those disposable sessions.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BANYAN_RUN_ADMISSION_INTEGRATION"] == "1"))
struct AgentAdmissionIntegrationTests {
    private func fixture(limit: Int) throws -> (PuckStoreFixture, TmuxBackend, UserDefaults, SessionStore) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let backend = TmuxBackend(environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "SHELL": "/bin/zsh", "HOME": fixture.home.path, "ZDOTDIR": fixture.home.path, "LANG": "en_US.UTF-8"],
            workingDirectory: fixture.project.path, socketName: "banyan-admission-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        defaults.set(limit, forKey: AgentAdmissionController.defaultsKey)
        let store = fixture.makeStore(tmuxBackend: backend, freezePreferences: defaults)
        return (fixture, backend, defaults, store)
    }

    @Test func restoredOverCapFleetKeepsRunningAndQueuedIntentSurvivesRelaunch() async throws {
        let (fixture, backend, defaults, store) = try fixture(limit: 3)
        defer { for session in store.terminalSessions { backend.killSession(named: session.tmuxSessionName) } }
        for index in 0..<3 {
            store.spawn(id: "restored-\(index)", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        }
        try await runtimeWait(store: store, backend: backend) { store.terminalSessions.allSatisfy(\.isProcessStarted) }
        try store.suspend(id: "restored-0")
        store.maximumConcurrentAgents = 1
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "/bin/sleep 1", select: false)
        #expect(queued.agentQueuePosition == 1)
        // Flush both deferred change callbacks and the serial persistence queue.
        try await Task.sleep(for: .milliseconds(50))
        store.flushPendingSessionSaves()
        let restored = fixture.makeStore(tmuxBackend: backend, freezePreferences: defaults)
        restored.loadPersistedSessionsIfNeeded()
        #expect(restored.agentAdmission.running.count == 3)
        #expect(restored.sessions.first { $0.id == "restored-0" }?.isSuspended == true)
        #expect(restored.sessions.first { $0.id == "queued" }?.agentQueuePosition == 1)
        for index in 0..<2 { try restored.close(id: "restored-\(index)") }
        try await runtimeWait(store: store, backend: backend) { restored.agentAdmission.running.count == 1 }
        #expect(!backend.hasSession(named: queued.tmuxSessionName))
        try restored.close(id: "restored-2")
        try await runtimeWait(store: store, backend: backend) { restored.sessions.first { $0.id == "queued" }?.isProcessStarted == true }
        #expect(restored.agentAdmission.running == ["queued"])
    }

    @Test func actualCloseLaunchRaceReapsTheLatePrivateAgentBeforeAdmittingNext() async throws {
        let (fixture, backend, defaults, _) = try fixture(limit: 1)
        let gated = AdmissionTerminalBackend()
        gated.delegate = backend
        let gate = DispatchSemaphore(value: 0)
        gated.launchGate = gate
        let store = fixture.makeStore(tmuxBackend: backend, sessionBackend: gated, freezePreferences: defaults)
        defer {
            gate.signal()
            for session in store.terminalSessions { backend.killSession(named: session.tmuxSessionName) }
        }
        let first = store.spawn(id: "late", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        try await runtimeWait(store: store, backend: backend) { gated.started.count == 1 }
        let next = store.spawn(id: "next", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        try store.close(id: first.id)
        #expect(store.agentAdmission.running == [first.id])
        #expect(!backend.hasSession(named: next.tmuxSessionName))
        gate.signal()
        try await runtimeWait(store: store, backend: backend) { gated.started.count == 2 }
        #expect(!backend.hasSession(named: first.tmuxSessionName))
        if let identity = first.admissionProcessIdentity {
            #expect(AgentProcessSample.read(pid: identity.pid)?.identity != identity)
        }
        gate.signal()
        try await runtimeWait(store: store, backend: backend) { next.isProcessStarted }
        #expect(store.agentAdmission.running == [next.id])
    }

    @Test func actualUninspectedLaunchRetainsCapacityAcrossDeniedLookupAndClose() async throws {
        let (fixture, backend, defaults, _) = try fixture(limit: 1)
        let denied = AdmissionTerminalBackend()
        denied.delegate = backend
        denied.omitPane = true
        denied.inspectionDenied = true
        let store = fixture.makeStore(tmuxBackend: backend, sessionBackend: denied, freezePreferences: defaults)
        defer { for terminal in store.terminalSessions { backend.killSession(named: terminal.tmuxSessionName) } }
        let first = store.spawn(id: "unknown", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        try await runtimeWait(store: store, backend: backend) { first.isProcessStarted }
        let pid = try #require(backend.primaryPaneSnapshot(named: first.tmuxSessionName)?.rootPID)
        let identity = try #require(AgentProcessSample.read(pid: Int32(pid))?.identity)
        let next = store.spawn(id: "next", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        try store.close(id: first.id)
        try await runtimeWait(store: store, backend: backend) { first.admissionInspectionError != nil }
        #expect(first.admissionPanePID == nil && store.agentAdmission.running == [first.id])
        #expect(next.agentQueuePosition == 1)
        denied.omitPane = false
        denied.inspectionDenied = false
        store.reconcileAgentAdmission(id: first.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.agentAdmission.running == [first.id])
        // A trusted provider identity is the missing evidence; pane absence
        // alone could not prove that the successful launch had ended.
        store.recordAgentProviderIdentity(id: first.id, identity: identity)
        store.confirmAgentProviderExit(id: first.id, identity: identity)
        try await runtimeWait(store: store, backend: backend) { next.isProcessStarted }
        #expect(store.agentAdmission.running == [next.id])
    }

    @Test func actualProviderExitReleasesPreservedPaneAndDeepResumeMustQueue() async throws {
        let (fixture, backend, _, store) = try fixture(limit: 1)
        defer { for session in store.terminalSessions { backend.killSession(named: session.tmuxSessionName) } }
        let script = fixture.root.appendingPathComponent("provider_parent.py")
        let pidFile = fixture.root.appendingPathComponent("provider.pid")
        try #"""
        import subprocess, sys, time
        child = subprocess.Popen(['/bin/sleep', '0.5'])
        with open(sys.argv[1], 'w') as f: f.write(str(child.pid))
        # Deliberately leave the child as a zombie before reaping it.
        time.sleep(3)
        child.wait()
        time.sleep(30)
        """#.write(to: script, atomically: true, encoding: .utf8)
        let command = "/usr/bin/python3 " + AgentLaunchCommand.shellQuote(script.path) + " " + AgentLaunchCommand.shellQuote(pidFile.path)
        let first = store.spawn(id: "preserved", cwd: fixture.project.path, command: command, select: false)
        try await runtimeWait(store: store, backend: backend) { first.isProcessStarted && FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let identity = try #require(AgentProcessSample.read(pid: pid)?.identity)
        store.recordAgentProviderIdentity(id: first.id, identity: identity)
        store.confirmAgentProviderExit(id: first.id, identity: identity)
        #expect(store.agentAdmission.running == [first.id]) // Still alive; cannot confirm early.
        let next = store.spawn(id: "next", cwd: fixture.project.path, command: "/bin/sleep 30", select: false)
        try await runtimeWait(store: store, backend: backend) { next.isProcessStarted }
        #expect(backend.primaryPaneSnapshot(named: first.tmuxSessionName)?.isDead == false)
        #expect(AgentProcessSample.read(pid: pid) == nil)
        #expect(kill(pid, 0) == 0) // Zombie remains unreaped by the private parent.
        #expect(store.agentAdmission.running == [next.id])
        var resumed = false
        #expect(!store.requestAgentAdmission(id: first.id, retry: { resumed = true }))
        store.confirmAgentProviderExit(id: first.id, identity: identity) // Stale provider callback.
        #expect(!resumed && store.agentAdmission.running == [next.id])
        try store.close(id: next.id)
        try await runtimeWait(store: store, backend: backend) { resumed }
        #expect(store.agentAdmission.running == [first.id])
    }

    @Test func syntheticFleetBoundsActualProcessesMemoryAndWorkerThreads() async throws {
        let (fixture, backend, _, store) = try fixture(limit: 2)
        defer { for session in store.terminalSessions { backend.killSession(named: session.tmuxSessionName) } }
        let script = fixture.root.appendingPathComponent("synthetic_agent.py")
        let log = fixture.root.appendingPathComponent("fleet.jsonl")
        try #"""
        import json, os, resource, sys, threading, time
        memory = bytearray(8 * 1024 * 1024)
        ready = threading.Barrier(4)
        gate = threading.Event()
        end = 0
        def spin():
            while time.monotonic() < end:
                sum(range(400))
        def worker():
            ready.wait()
            gate.wait()
            spin()
        workers = [threading.Thread(target=worker) for _ in range(3)]
        def event(kind):
            row = dict(kind=kind, at=time.time_ns(), pid=os.getpid(), cpu=time.process_time(),
                       rss=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, threads=threading.active_count())
            fd = os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_APPEND, 0o600)
            os.write(fd, (json.dumps(row)+'\n').encode()); os.close(fd)
        for thread in workers: thread.start()
        ready.wait()
        event('start')
        end = time.monotonic() + 0.7
        gate.set()
        spin()
        for thread in workers: thread.join()
        event('end')
        """#.write(to: script, atomically: true, encoding: .utf8)
        let command = "/usr/bin/python3 " + AgentLaunchCommand.shellQuote(script.path) + " " + AgentLaunchCommand.shellQuote(log.path)
        for index in 0..<12 {
            store.spawn(id: "synthetic-\(index)", cwd: fixture.project.path, command: command, select: false)
        }
        #expect(store.agentAdmission.running.count == 2)
        #expect(store.agentAdmission.queuedIDs.count == 10)
        try await runtimeWait(timeout: .seconds(30), store: store, backend: backend) { store.agentAdmission.running.isEmpty && store.agentAdmission.queuedIDs.isEmpty }
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.sorted { ($0["at"] as! Int64) < ($1["at"] as! Int64) }
        var running: [Int: [String: Any]] = [:]
        var peakProcesses = 0, peakRSS = 0, peakThreads = 0, cpuSeconds = 0.0
        for row in rows {
            let pid = row["pid"] as! Int
            if row["kind"] as? String == "start" {
                running[pid] = row
                peakProcesses = max(peakProcesses, running.count)
                peakRSS = max(peakRSS, running.values.reduce(0) { $0 + ($1["rss"] as! Int) })
                peakThreads = max(peakThreads, running.values.reduce(0) { $0 + ($1["threads"] as! Int) })
            } else {
                cpuSeconds += (row["cpu"] as! Double) - ((running[pid]?["cpu"] as? Double) ?? 0)
                running.removeValue(forKey: pid)
            }
        }
        #expect(rows.count == 24)
        #expect(peakProcesses == 2)
        #expect(peakThreads == 8)
        #expect(running.isEmpty)
        #expect(cpuSeconds > 0)
        // Local artifact only: no machine paths or measured host values in source.
        let report: [String: Any] = ["agents": 12, "limit": 2, "peakProcesses": peakProcesses,
            "peakSampledPythonThreads": peakThreads, "peakSumOfStartSampledProcessHighWaterRSSBytes": peakRSS, "cpuSeconds": cpuSeconds]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("Synthetic admission fleet: " + String(decoding: data, as: UTF8.self))
    }
}

@MainActor
private func runtimeWait(timeout: Duration = .seconds(5), store: SessionStore, backend: TmuxBackend,
                         line: Int = #line, until predicate: () -> Bool) async throws {
    do { try await waitForPuckState(timeout: timeout, until: predicate) }
    catch {
        print("Runtime wait failed at line \(line). Slots: \(store.agentAdmission.running), queue: \(store.agentAdmission.queuedIDs)")
        for terminal in store.terminalSessions {
            let pane = backend.primaryPaneSnapshot(named: terminal.tmuxSessionName)
            print("  \(terminal.id) started=\(terminal.isProcessStarted) status=\(terminal.status) pid=\(String(describing: terminal.admissionPanePID)) pane=\(String(describing: pane)) error=\(terminal.admissionInspectionError ?? "none")")
        }
        throw error
    }
}
