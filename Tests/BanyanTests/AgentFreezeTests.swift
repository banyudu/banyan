import AppKit
import Darwin
import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// Every signal target in this suite is a synthetic Python agent on a UUID
/// tmux socket. The TCP peer is outside the pane and expires a keep-alive while
/// the agent is stopped, exercising reconnect without any provider credentials.
@Suite(.serialized)
@MainActor
struct AgentFreezeTests {
    @Test func syntheticAgentFreezeStopsMCPRetainsMemoryAndReconnects() async throws {
        let processes = FreezeInspectionCounter()
        let f = try await FreezeFixture(processTable: processes)
        defer { f.cleanup() }
        let before = try #require(AgentProcessSample.read(pid: f.agentPID))
        #expect(before.residentBytes > 32 * 1024 * 1024)
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        #expect(f.session.isFrozen)
        #expect(!f.session.isSuspended)
        #expect(ticket.groups.count >= 2) // dedicated MCP job-control group
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == ticket)
        try await waitForPuckState { f.allStopped(ticket) }
        let frozenStatus = f.session.status
        let inspectionCount = processes.count
        try f.store.tick(id: f.session.id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(processes.count == inspectionCount) // Frozen rows incur no classification.
        #expect(!f.store.applySupervisorResults([
            .init(id: f.session.id, status: .executing, tone: .blue, provider: .codex, currentPath: nil)
        ])) // An inspection started before STOP must not overwrite the frozen row.
        #expect(f.session.status == frozenStatus)
        #expect(AgentProcessSample.read(pid: f.rootPID)?.isStopped == false) // tmux host stays alive
        let heartbeat = f.heartbeat()
        try await Task.sleep(for: .milliseconds(250))
        #expect(f.heartbeat() == heartbeat)
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == before.identity)
        // STOP preserves the address space; it does not promise immediate RAM release.
        #expect(AgentProcessSample.read(pid: f.agentPID)?.residentBytes ?? 0 > 0)
        print("Synthetic freeze evidence: groups=\(ticket.groups.count) RSS before=\(before.residentBytes) stopped=\(AgentProcessSample.read(pid: f.agentPID)?.residentBytes ?? 0)")
        try Data().write(to: f.fixture.root.appendingPathComponent("expire"))
        try await waitForPuckState { FileManager.default.fileExists(atPath: f.fixture.root.appendingPathComponent("expired").path) }
        _ = try await f.store.injectInput(id: f.session.id, keys: [], text: "ping", submit: true)
        #expect(!f.session.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
        try await waitForPuckState {
            f.backend.captureVisibleText(paneID: f.paneID, lineLimit: 30).contains("reconnected pong memory=67108864")
        }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == before.identity)
        try await waitForPuckState { f.heartbeat() != heartbeat }
    }

    @Test func syntheticAgentSelectionResumesAndBusyFocusedParkedSessionsRefuse() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        f.store.selectedSessionID = f.session.id
        await #expect(throws: (any Error).self) { try await f.store.freezeAgent(id: f.session.id) }
        f.store.selectedSessionID = nil
        f.session.status = .executing
        await #expect(throws: (any Error).self) { try await f.store.freezeAgent(id: f.session.id) }
        f.session.status = .idle
        f.session.isSuspended = true
        await #expect(throws: (any Error).self) { try await f.store.freezeAgent(id: f.session.id) }
        f.session.isSuspended = false
        f.session.lastFreezeInteractionAt = .distantPast
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        f.store.selection.selectedSessionID = f.session.id
        #expect(!f.session.isFrozen)
        try await waitForPuckState { !f.allStopped(ticket) }
    }

    @Test func syntheticAgentFocusDuringPreparationCancelsFreeze() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        let preparation = Task { try await f.store.freezeAgent(id: f.session.id) }
        try await Task.sleep(for: .milliseconds(150))
        f.store.selectedSessionID = f.session.id
        await #expect(throws: (any Error).self) { try await preparation.value }
        #expect(!f.session.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func syntheticAgentUserStopHasExplicitRecoveryWithoutFreezeTicket() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        #expect(f.session.frozenTicket == nil)
        #expect(kill(-f.agentPID, SIGTSTP) == 0)
        try await waitForPuckState { AgentProcessSample.read(pid: f.agentPID)?.isStopped == true }
        try await Task.sleep(for: .milliseconds(150))
        #expect(AgentProcessSample.read(pid: f.agentPID)?.isStopped == true)
        try f.store.unfreezeAgent(id: f.session.id)
        try await waitForPuckState { AgentProcessSample.read(pid: f.agentPID)?.isStopped == false }
        #expect(f.session.frozenTicket == nil)
        f.session.lastFreezeInteractionAt = .distantPast
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.allStopped(ticket)) // host never auto-resumes Banyan-owned STOP
    }

    @Test func syntheticAgentBusyMCPRefusesFreezeAndExternalContinueIsReconciled() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        let busy = f.fixture.root.appendingPathComponent("busy")
        try Data().write(to: busy)
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: (any Error).self) { try await f.store.freezeAgent(id: f.session.id) }
        #expect(!f.session.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
        try FileManager.default.removeItem(at: busy)
        try await Task.sleep(for: .milliseconds(150))
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        try AgentProcessFreezer.unfreeze(ticket) // synthetic external CONT
        f.store.reconcileFrozenAgents()
        try await waitForPuckState { !f.session.isFrozen }
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func syntheticAgentAutomaticPolicyRunsWhenEnabledAndShutdownResumes() async throws {
        let f = try await FreezeFixture(agedActivity: true)
        defer { f.cleanup() }
        let defaults = f.store.freezePreferences
        let previous = defaults.object(forKey: "autoFreezeAgents")
        let previousMinutes = defaults.object(forKey: "agentFreezeIdleMinutes")
        defer {
            f.store.autoFreezeAgents = false
            if let previous { defaults.set(previous, forKey: "autoFreezeAgents") }
            else { defaults.removeObject(forKey: "autoFreezeAgents") }
            if let previousMinutes { defaults.set(previousMinutes, forKey: "agentFreezeIdleMinutes") }
            else { defaults.removeObject(forKey: "agentFreezeIdleMinutes") }
        }
        f.store.autoFreezeAgents = false
        f.session.lastFreezeInteractionAt = .distantPast
        f.store.runAutoFreezePassIfNeeded()
        #expect(!f.session.isFrozen)
        f.store.autoFreezeAgents = true
        f.session.lastFreezeInteractionAt = .distantPast
        f.store.agentFreezeIdleMinutes = 1
        f.store.runAutoFreezePassIfNeeded()
        try await waitForPuckState(timeout: .seconds(10)) { f.session.isFrozen }
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        // Disabling the opt-in releases already stopped agents too.
        f.store.autoFreezeAgents = false
        #expect(!f.session.isFrozen)
        f.session.status = .idle
        f.session.lastFreezeInteractionAt = .distantPast
        try await f.store.freezeAgent(id: f.session.id)
        f.store.prepareForAgentFreezeShutdown()
        #expect(!f.session.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
        await #expect(throws: (any Error).self) { try await f.store.freezeAgent(id: f.session.id) }
    }

    @Test func syntheticAgentJournalRecoveryAndRemovalResumeStoppedChildren() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        // A new frontend knows nothing about the old object's runtime fields.
        let restored = TerminalSession(id: f.session.id, tmuxSessionName: f.session.tmuxSessionName,
            title: "Restored", cwd: f.fixture.project.path, command: f.session.command,
            status: .idle, isRestored: true, theme: .system, tmuxBackend: f.backend,
            telemetry: banyanTestTelemetry, host: banyanTestHost)
        restored.trackPaneIdentityIfNeeded()
        #expect(restored.isFrozen)
        #expect(restored.frozenTicket == ticket)
        try restored.unfreezeAgent()
        #expect(!restored.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
        f.session.frozenTicket = nil
        f.session.isFrozen = false
        f.session.status = .idle
        try await f.store.freezeAgent(id: f.session.id)
        try f.store.remove(id: f.session.id)
        #expect(!f.backend.hasSession(named: f.session.tmuxSessionName))
        try await waitForPuckState {
            ticket.members.allSatisfy { AgentProcessSample.read(pid: $0.pid)?.identity != $0 }
        }
    }

    @Test func syntheticAgentFrozenRestartCleansOwnedMCPGroups() async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        try Data().write(to: f.fixture.root.appendingPathComponent("expire"))
        try await waitForPuckState { FileManager.default.fileExists(atPath: f.fixture.root.appendingPathComponent("expired").path) }
        try FileManager.default.removeItem(at: f.fixture.root.appendingPathComponent("ready"))
        try f.store.restart(id: f.session.id)
        try await waitForPuckState { FileManager.default.fileExists(atPath: f.fixture.root.appendingPathComponent("ready").path) }
        let pane = try #require(f.backend.primaryPaneSnapshot(named: f.session.tmuxSessionName))
        #expect(AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity != ticket.root)
        #expect(!f.session.isFrozen)
        #expect(f.backend.freezeTicket(named: f.session.tmuxSessionName) == nil)
        try await waitForPuckState {
            ticket.members.allSatisfy { AgentProcessSample.read(pid: $0.pid)?.identity != $0 }
        }
    }

    @Test(arguments: [false, true])
    func syntheticAgentRestoredInteractionOrShutdownResumesBeforeJournalCallback(shutdown: Bool) async throws {
        let f = try await FreezeFixture()
        defer { f.cleanup() }
        try await f.store.freezeAgent(id: f.session.id)
        let ticket = try #require(f.session.frozenTicket)
        try await waitForPuckState { f.allStopped(ticket) }
        let other = f.store.spawn(id: "restored-other", title: "Other terminal", cwd: f.fixture.project.path,
                                  command: "", select: false)
        try f.backend.ensureSession(named: other.tmuxSessionName, cwd: other.cwd, command: "", banyanSessionID: other.id)
        f.store.flushPendingSessionSaves()
        f.fixture.persistence.save([other.persistenceSnapshot, f.session.persistenceSnapshot])
        let store = f.fixture.makeStore(tmuxBackend: f.backend, processTable: LiveProcessTableProvider(),
                                       freezePreferences: f.store.freezePreferences)
        store.loadPersistedSessionsIfNeeded()
        let restored = try #require(store.terminalSessions.first { $0.id == f.session.id })
        #expect(!restored.isFrozen) // no journal callback has populated state yet
        #expect(f.backend.freezeTicket(named: restored.tmuxSessionName) == ticket)
        if shutdown { store.prepareForAgentFreezeShutdown() }
        else { store.resumeFrozenForInteraction(id: restored.id) }
        #expect(!restored.isFrozen)
        #expect(f.backend.freezeTicket(named: restored.tmuxSessionName) == nil)
        try await waitForPuckState { !f.allStopped(ticket) }
    }
}

@MainActor
private struct FreezeFixture {
    let fixture: PuckStoreFixture
    let backend: TmuxBackend
    let store: SessionStore
    let session: TerminalSession
    let peer: Process
    let rootPID: Int32
    let agentPID: Int32
    let paneID: String
    let cleanupTicket: AgentFreezeTicket

    init(agedActivity: Bool = false, processTable: any ProcessTableProvider = LiveProcessTableProvider()) async throws {
        fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = fixture.home.path
        environment["SHELL"] = "/bin/sh"
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = [".build/debug/banyanctl", ".build/out/Products/Debug/banyanctl"].map { package.appendingPathComponent($0).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        let processHost = try #require(host)
        environment["BANYAN_PROCESS_HOST"] = processHost
        backend = TmuxBackend(environment: environment,
            workingDirectory: fixture.project.path, socketName: "banyan-freeze-test-\(UUID().uuidString)")
        let directory = fixture.root.path
        let peerScript = fixture.root.appendingPathComponent("peer.py")
        try Self.peerScript.write(to: peerScript, atomically: true, encoding: .utf8)
        let agentScript = fixture.root.appendingPathComponent("codex")
        try Self.agentScript.write(to: agentScript, atomically: true, encoding: .utf8)
        try Self.mcpScript.write(to: fixture.root.appendingPathComponent("mcp-server.py"), atomically: true, encoding: .utf8)
        peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        peer.arguments = [peerScript.path, directory]
        peer.standardOutput = FileHandle.nullDevice
        peer.standardError = FileHandle.nullDevice
        try peer.run()
        let port = fixture.root.appendingPathComponent("port")
        try await waitForPuckState { FileManager.default.fileExists(atPath: port.path) }
        store = fixture.makeStore(tmuxBackend: backend,
                                  sessionBackend: agedActivity ? AgedFreezeBackend(base: backend) : nil,
                                  processTable: processTable,
                                  freezePreferences: try #require(UserDefaults(suiteName: backend.socketName)))
        let command = "exec /usr/bin/python3 " + AgentLaunchCommand.shellQuote(agentScript.path) + " " + AgentLaunchCommand.shellQuote(directory)
        session = store.spawn(id: "synthetic-freeze", title: "Synthetic agent", cwd: fixture.project.path,
                              command: command, select: false)
        let ready = fixture.root.appendingPathComponent("ready")
        try await waitForPuckState { FileManager.default.fileExists(atPath: ready.path) }
        let pane = try #require(backend.primaryPaneSnapshot(named: session.tmuxSessionName))
        rootPID = Int32(pane.rootPID)
        agentPID = Int32(try #require(ProcessTable.snapshot().descendants(of: pane.rootPID).first { $0.isSupportedAgentForFreezing }) .pid)
        paneID = pane.paneID
        cleanupTicket = try AgentProcessFreezer.plan(root: try #require(AgentProcessSample.read(pid: rootPID)).identity,
            agentPIDs: [agentPID], samples: AgentProcessFreezer.snapshot(rootPID: rootPID))
        session.status = .idle
        session.lastFreezeInteractionAt = .distantPast
        try await Task.sleep(for: .seconds(2.1))
    }

    func allStopped(_ ticket: AgentFreezeTicket) -> Bool {
        let rows = ProcessTable.snapshot().descendants(of: Int(rootPID))
        return ticket.members.allSatisfy { identity in rows.contains { $0.pid == identity.pid && $0.state.hasPrefix("T") } }
    }

    func heartbeat() -> String {
        (try? String(contentsOf: fixture.root.appendingPathComponent("heartbeat"), encoding: .utf8)) ?? ""
    }

    func cleanup() {
        // Tests own this synthetic tree even after unfreeze/normal agent exit.
        // Production deliberately preserves background children without a
        // frozen teardown ticket; fixture cleanup must not depend on that path.
        try? AgentProcessFreezer.terminate(cleanupTicket)
        if let pane = backend.primaryPaneSnapshot(named: session.tmuxSessionName),
           let root = AgentProcessSample.read(pid: Int32(pane.rootPID))?.identity {
            let agents = Set(ProcessTable.snapshot().descendants(of: pane.rootPID)
                .filter { $0.isSupportedAgentForFreezing }.map { Int32($0.pid) })
            if let samples = try? AgentProcessFreezer.snapshot(rootPID: root.pid),
               let ticket = try? AgentProcessFreezer.plan(root: root, agentPIDs: agents, samples: samples) {
                try? AgentProcessFreezer.terminate(ticket)
            }
        }
        for session in store.terminalSessions { session.killBackingSession() }
        if peer.isRunning { peer.terminate(); peer.waitUntilExit() }
        store.freezePreferences.removePersistentDomain(forName: backend.socketName)
    }

    private static let peerScript = #"""
    import socket, sys, time, pathlib
    root = pathlib.Path(sys.argv[1])
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    (root / 'port').write_text(str(listener.getsockname()[1]))
    connection, _ = listener.accept()
    connection.sendall(b'hello')
    while not (root / 'expire').exists(): time.sleep(0.02)
    connection.close()
    (root / 'expired').touch()
    connection, _ = listener.accept()
    connection.sendall(b'hello')
    while connection.recv(1024): connection.sendall(b'pong')
    """#

    private static let agentScript = #"""
    import os, pathlib, socket, subprocess, sys
    root = pathlib.Path(sys.argv[1])
    memory = bytearray(b'x') * (64 * 1024 * 1024)
    child = subprocess.Popen([sys.executable, str(root / 'mcp-server.py'), str(root)], preexec_fn=os.setpgrp)
    def connect():
        s = socket.create_connection(('127.0.0.1', int((root / 'port').read_text())))
        s.recv(1024)
        return s
    connection = connect()
    print('OpenAI Codex (v0.synthetic)\n> ', flush=True)
    (root / 'ready').touch()
    for line in sys.stdin:
        try:
            connection.sendall(b'ping')
            if not connection.recv(1024): raise ConnectionError('expired')
        except OSError:
            connection.close()
            connection = connect()
            connection.sendall(b'ping')
            answer = connection.recv(1024).decode()
            print('reconnected ' + answer + ' memory=' + str(len(memory)), flush=True)
    """#

    private static let mcpScript = #"""
    import pathlib, sys, time
    root = pathlib.Path(sys.argv[1])
    while True:
        while (root / 'busy').exists(): pass
        (root / 'heartbeat').write_text(str(time.monotonic_ns()))
        time.sleep(0.1)
    """#
}

private final class FreezeInspectionCounter: ProcessTableProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return snapshots }
    func snapshot() -> ProcessTable {
        lock.lock(); snapshots += 1; lock.unlock()
        return .snapshot()
    }
}

/// Alters time only. All process sampling, group signals, tmux input, journal
/// writes and cleanup still reach the fixture's private backend.
private struct AgedFreezeBackend: TmuxClientBackend {
    let base: TmuxBackend
    var executableURL: URL { base.executableURL }
    func hasSession(named name: String) -> Bool { base.hasSession(named: name) }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        guard let p = base.primaryPaneSnapshot(named: name) else { return nil }
        return TmuxPaneSnapshot(paneID: p.paneID, rootPID: p.rootPID, currentCommand: p.currentCommand,
            currentPath: p.currentPath, isDead: p.isDead, isInMode: p.isInMode,
            lastActivityAt: p.lastActivityAt?.addingTimeInterval(-3600), width: p.width, height: p.height,
            hasAttachedClients: p.hasAttachedClients)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { base.captureVisibleText(paneID: paneID, lineLimit: lineLimit) }
    func captureCurrentVisibleText(paneID: String) -> String { base.captureCurrentVisibleText(paneID: paneID) }
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws {
        try base.ensureSession(named: name, cwd: cwd, command: command, banyanSessionID: banyanSessionID)
    }
    func killSession(named name: String) { base.killSession(named: name) }
    func attachArguments(for name: String) -> [String] { base.attachArguments(for: name) }
    func configureTerminalTheme(style: String, for sessionName: String?) { base.configureTerminalTheme(style: style, for: sessionName) }
    func refreshClients(attachedTo name: String) { base.refreshClients(attachedTo: name) }
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {
        base.scrollHistory(paneID: paneID, lines: lines, up: up, onScrollPosition: onScrollPosition)
    }
    func freezeTicket(named name: String) -> AgentFreezeTicket? { base.freezeTicket(named: name) }
    func writeFreezeTicket(_ ticket: AgentFreezeTicket?, named name: String) throws { try base.writeFreezeTicket(ticket, named: name) }
}
