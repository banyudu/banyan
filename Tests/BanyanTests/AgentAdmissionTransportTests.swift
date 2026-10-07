import Foundation
import Network
import Testing
@testable import Banyan
@testable import BanyanCore

@MainActor
@Suite(.serialized)
struct AgentAdmissionTransportTests {
    @Test func actualCLIAcceptsOneHundredSlotsAndRestoresTheSavedLimit() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let preferences = privateDefaults()
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: preferences)
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }

        let result = try await cli(store: store, server: server, arguments: ["agent", "queue", "limit", "100"])
        #expect(result.terminationStatus == 0)
        #expect(store.maximumConcurrentAgents == 100 && store.agentAdmission.limit == 100)
        #expect(preferences.integer(forKey: AgentAdmissionController.defaultsKey) == 100)

        let restored = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: preferences)
        defer { restored.stopPuckObservation() }
        #expect(restored.maximumConcurrentAgents == 100 && restored.agentAdmission.limit == 100)

        let refused = try await cli(store: store, server: server, arguments: ["agent", "queue", "limit", "101"])
        #expect(refused.terminationStatus != 0)
        #expect(store.maximumConcurrentAgents == 100)

        preferences.removeObject(forKey: AgentAdmissionController.defaultsKey)
        let fresh = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: preferences)
        defer { fresh.stopPuckObservation() }
        #expect(fresh.maximumConcurrentAgents == 100 && fresh.agentAdmission.limit == 100)
    }

    @Test func actualCLITerminalSpawnReturnsItsQueuedRowAndCancelPreventsLaunch() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let backend = AdmissionTerminalBackend()
        let store = fixture.makeStore(sessionBackend: backend, freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        store.agentAdmission.adopt("existing-work")
        let response = try await cli(store: store, server: server, arguments: ["spawn", "--id", "queued-cli", "--cwd", fixture.project.path,
            "--command", "synthetic-agent", "--background"])
        #expect(response.terminationStatus == 0)
        let queued = try #require(store.sessions.first { $0.id == "queued-cli" })
        #expect(queued.agentQueuePosition == 1 && backend.started.isEmpty)
        let input = try await cli(store: store, server: server, arguments: ["send", "--id", queued.id, "--text", "Must not send", "--submit"])
        #expect(input.terminationStatus != 0)
        let cancel = try await cli(store: store, server: server, arguments: ["agent", "queue", "cancel", queued.id])
        #expect(cancel.terminationStatus == 0 && queued.agentLaunchQueue?.cancelled == true)
        store.agentAdmission.release("existing-work")
        #expect(backend.started.isEmpty && store.agentAdmission.queuedIDs.isEmpty)
    }

    @Test func actualCLIRefusesBusyPuckTurnsWithoutLatentDeliveryAndRetainsRemovedWork() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        let puck = try await store.createPuckSession(binding: .init(provider: "codex"), cwd: fixture.project.path, id: "cli", select: false)
        store.agentAdmission.adopt("existing-work")
        let refused = try await cli(store: store, server: server, arguments: ["puck", "turn", "--id", puck.id, "--prompt", "Synthetic prompt"])
        #expect(refused.terminationStatus != 0)
        #expect(String(decoding: refused.standardError, as: UTF8.self).contains("Nothing was queued"))
        #expect(daemon.turns.isEmpty && store.agentAdmission.queuedIDs.isEmpty)
        store.agentAdmission.release("existing-work")
        try await Task.sleep(for: .milliseconds(50))
        #expect(daemon.turns.isEmpty)
        let accepted = try await cli(store: store, server: server, arguments: ["puck", "turn", "--id", puck.id, "--prompt", "Explicit retry"])
        #expect(accepted.terminationStatus == 0)
        #expect(daemon.turns.map(\.prompt) == ["Explicit retry"])
        #expect(store.agentAdmission.running == [puck.id])
        try store.remove(id: puck.id)
        #expect(!store.sessions.contains { $0.id == puck.id })
        #expect(store.agentAdmission.running == [puck.id])
        let replacement = store.spawn(id: puck.id, cwd: fixture.project.path, command: "synthetic-agent", select: false)
        #expect(replacement.id != puck.id && replacement.agentQueuePosition == 1)
        store.cancelQueuedAgent(id: replacement.id)
        let idle = try daemon.get(puck.id).with(position: "idle")
        store.applyPuckSummaries([idle])
        #expect(store.agentAdmission.running.isEmpty)
        let reused = store.spawn(id: puck.id, cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { reused.isProcessStarted }
        #expect(reused.id == puck.id && store.agentAdmission.running == [reused.id])
        puck.apply(summary: idle) // Late event from the retired Puck object.
        store.applyPuckSummaries([idle])
        store.applyPuckSummaries([])
        #expect(store.agentAdmission.running == [reused.id])
    }

    @Test func actualCLIPuckTurnCannotReuseATerminalReservationWithTheSameID() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let terminal = store.spawn(id: "shared-id", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { terminal.isProcessStarted }
        daemon.put(puckSummary(id: terminal.id, cwd: fixture.project.path))
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        let result = try await cli(store: store, server: server, arguments: ["puck", "turn", "--id", terminal.id, "--prompt", "Must not alias"])
        #expect(result.terminationStatus != 0)
        #expect(daemon.turns.isEmpty && store.agentAdmission.running == [terminal.id])
        #expect(store.sessions.filter { $0.id == terminal.id }.count == 1)
    }

    @Test func actualCLIPuckProfileCreationRefusesInitialPromptBeforeQueueing() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        store.agentAdmission.adopt("existing-work")
        let result = try await cli(store: store, server: server, arguments: ["agent", "run", "--profile", "codex-puck",
            "--id", "created", "--cwd", fixture.project.path, "--prompt", "Must not queue", "--background"])
        #expect(result.terminationStatus != 0)
        #expect(daemon.creations.count == 1 && daemon.turns.isEmpty)
        #expect(store.sessions.contains { $0.id == "created" })
        #expect(store.agentAdmission.queuedIDs.isEmpty)
        store.agentAdmission.release("existing-work")
        try await Task.sleep(for: .milliseconds(50))
        #expect(daemon.turns.isEmpty)
    }

    @Test func actualCLIWhitespaceInitialPromptCannotReserveAnUnusedSlot() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        let result = try await cli(store: store, server: server, arguments: ["agent", "run", "--profile", "codex-puck",
            "--id", "empty", "--cwd", fixture.project.path, "--prompt", " \n ", "--background"])
        #expect(result.terminationStatus != 0)
        #expect(daemon.turns.isEmpty && store.agentAdmission.running.isEmpty && store.agentAdmission.queuedIDs.isEmpty)
    }

    @Test func actualCLITimeoutCannotLeaveALatePromptQueuedOrFallBackToDaemon() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        daemon.put(puckSummary(id: "slow", cwd: fixture.project.path))
        let gate = daemon.holdGets()
        defer { gate.signal() }
        let request = Task { try await cli(store: store, server: server, arguments: ["puck", "turn", "--id", "slow", "--prompt", "Must expire"]) }
        try await waitForPuckState { daemon.getsStarted == 1 }
        let response = try await request.value
        #expect(response.terminationStatus != 0)
        #expect(String(decoding: response.standardError, as: UTF8.self).contains("uncertain"))
        gate.signal()
        try await waitForPuckState { store.sessions.contains { $0.id == "slow" } }
        #expect(daemon.turns.isEmpty && store.agentAdmission.running.isEmpty && store.agentAdmission.queuedIDs.isEmpty)
    }

    @Test func connectionRefusalExplicitlyAllowsOfflinePuckDelivery() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        server.stop()
        var environment = store.host.environment
        environment["BANYAN_FIXTURE_CONTROL_URL"] = "http://127.0.0.1:\(port)"
        let offline = try await Task.detached {
            try PuckAppAdmission.turn("offline", prompt: "Synthetic offline prompt", environment: environment)
        }.value
        #expect(!offline)
    }

    @Test func controlAPIClampsLongClientExpiryBeforeSlowLookup() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend(), freezePreferences: privateDefaults())
        let server = ControlServer(store: store, host: store.host, port: .any)
        server.start()
        defer { server.stop(); store.stopPuckObservation() }
        try await waitForPuckState { server.listeningPort != nil }
        daemon.put(puckSummary(id: "long-expiry", cwd: fixture.project.path))
        let gate = daemon.holdGets()
        defer { gate.signal() }
        let port = try #require(server.listeningPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/puck-turn")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue(try ControlToken.loadOrCreate(environment: store.host.environment, homeDirectory: store.host.homeDirectory),
                         forHTTPHeaderField: ControlToken.headerName)
        request.httpBody = try JSONEncoder().encode(ControlPayload(id: "long-expiry", text: "Must expire", ttl: Int(Date().timeIntervalSince1970) + 300))
        let delivery = Task { try await URLSession.shared.data(for: request) }
        try await waitForPuckState { daemon.getsStarted == 1 }
        do {
            _ = try await delivery.value
            Issue.record("A blocked lookup unexpectedly completed")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        gate.signal()
        try await waitForPuckState { store.sessions.contains { $0.id == "long-expiry" } }
        #expect(daemon.turns.isEmpty && store.agentAdmission.running.isEmpty && store.agentAdmission.queuedIDs.isEmpty)
    }

    private func privateDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        defaults.set(1, forKey: AgentAdmissionController.defaultsKey)
        return defaults
    }

    private func cli(store: SessionStore, server: ControlServer, arguments: [String]) async throws -> SubprocessRunner.Output {
        let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/banyanctl")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let port = try #require(server.listeningPort)
        var environment = store.host.environment
        environment["BANYAN_FIXTURE_CONTROL_URL"] = "http://127.0.0.1:\(port)"
        return try await SubprocessRunner.runAsync(arguments: [executable.path] + arguments,
            cwd: store.host.currentDirectory, environment: environment, timeout: 8)
    }
}
