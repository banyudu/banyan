import AppKit
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

final class AdmissionTerminalBackend: TmuxClientBackend, @unchecked Sendable {
    let executableURL = URL(fileURLWithPath: "/usr/bin/false")
    private let lock = NSLock()
    private var live: Set<String> = []
    private var launches: [String] = []
    var delegate: TmuxBackend?
    var failure: String?
    var inspectionDenied = false
    var omitPane = false
    var launchGate: DispatchSemaphore?
    var started: [String] { lock.withLock { launches } }
    func hasSession(named: String) -> Bool {
        if let delegate { return delegate.hasSession(named: named) }
        return lock.withLock { live.contains(named) }
    }
    /// `nil` mirrors a backend that cannot report window activity; the admission
    /// tests that exercise quiet-window yielding set it explicitly.
    var paneLastActivityAt: Date?
    func primaryPaneSnapshot(named: String) -> TmuxPaneSnapshot? {
        guard !omitPane else { return nil }
        if let delegate { return delegate.primaryPaneSnapshot(named: named) }
        guard !omitPane, hasSession(named: named) else { return nil }
        return .init(paneID: "%1", rootPID: 2_000_000, currentCommand: "synthetic-agent", currentPath: "/tmp", isDead: false, isInMode: false, lastActivityAt: paneLastActivityAt)
    }
    func agentAdmissionPane(named name: String) -> AgentAdmissionPaneInspection {
        if inspectionDenied { return .unknown }
        if let delegate { return delegate.agentAdmissionPane(named: name) }
        if let pane = primaryPaneSnapshot(named: name) { return .present(pane) }
        return hasSession(named: name) ? .unknown : .absent
    }
    func ensureSession(named: String, cwd: String, command: String, banyanSessionID: String?) throws {
        lock.withLock { launches.append(named) }
        launchGate?.wait()
        if let delegate {
            try delegate.ensureSession(named: named, cwd: cwd, command: command, banyanSessionID: banyanSessionID)
            return
        }
        if failure == named { throw ControlError.badRequest("Synthetic launch failure") }
        _ = lock.withLock { live.insert(named) }
    }
    func killSession(named: String) {
        if let delegate { delegate.killSession(named: named); return }
        _ = lock.withLock { live.remove(named) }
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
    func captureCurrentVisibleText(paneID: String) -> String { "" }
    func attachArguments(for name: String) -> [String] { [] }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
    func freezeTicket(named: String) -> AgentFreezeTicket? { nil }
    func writeFreezeTicket(_ ticket: AgentFreezeTicket?, named: String) throws {}
}

@MainActor
@Suite(.serialized) struct SessionAgentAdmissionTests {
    private func fixture() throws -> (PuckStoreFixture, AdmissionTerminalBackend, SessionStore) {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let backend = AdmissionTerminalBackend()
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        let store = fixture.makeStore(sessionBackend: backend, freezePreferences: defaults)
        store.maximumConcurrentAgents = 1
        return (fixture, backend, store)
    }

    @Test func selectionParkingFreezingAndPlainShellsDoNotBypassCap() async throws {
        let (fixture, backend, store) = try fixture()
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        first.admissionProcessProbe = { _, _ in .exited }
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: true)
        #expect(store.selectedSessionID == queued.id)
        #expect(queued.agentQueuePosition == 1)
        queued.startAsync()
        queued.startBackgroundBackendIfNeeded()
        #expect(backend.started == [first.tmuxSessionName])
        try store.suspend(id: first.id)
        first.isFrozen = true // Policy accounting is independent of both frontend flags.
        #expect(store.agentAdmission.running == [first.id])
        let shell = store.spawn(id: "shell", cwd: fixture.project.path, command: "", select: false)
        try await waitForPuckState { shell.isProcessStarted }
        #expect(!store.agentAdmission.running.contains(shell.id))
        #expect(queued.agentQueuePosition == 1)
        first.isFrozen = false
        backend.killSession(named: first.tmuxSessionName)
        store.reconcileAgentAdmission(id: first.id)
        try await waitForPuckState { queued.isProcessStarted }
        #expect(store.selectedSessionID == queued.id)
        #expect(store.agentAdmission.running == [queued.id])
        let summary = ControlServer(store: store, host: store.host).summary(queued)
        #expect(summary["usesAgentSlot"] as? Bool == true)
        #expect(summary["agentQueuePosition"] is NSNull)
    }

    @Test func cancellationFailureAndExplicitRetryReleaseCapacityWithoutLaunchingCancelledRows() async throws {
        let (fixture, backend, store) = try fixture()
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        first.admissionProcessProbe = { _, _ in .exited }
        let cancelled = store.spawn(id: "cancel", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        backend.failure = "banyan-failed"
        let failed = store.spawn(id: "failed", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        let last = store.spawn(id: "last", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        store.prioritizeQueuedAgent(id: last.id)
        #expect(last.agentLaunchQueue!.requestedAt < failed.agentLaunchQueue!.requestedAt)
        store.prioritizeQueuedAgent(id: failed.id)
        store.cancelQueuedAgent(id: cancelled.id)
        cancelled.startBackgroundBackendIfNeeded()
        #expect(cancelled.agentLaunchQueue?.cancelled == true)
        backend.killSession(named: first.tmuxSessionName)
        store.reconcileAgentAdmission(id: first.id)
        try await waitForPuckState { last.isProcessStarted }
        #expect(failed.status == .failed)
        #expect(!backend.started.contains(cancelled.tmuxSessionName))
        #expect(store.agentAdmission.running == [last.id])
        store.retryQueuedAgent(id: cancelled.id)
        #expect(cancelled.agentQueuePosition == 1)
    }

    /// The reported wedge: a fleet of idle CLI commands above the cap held every
    /// reservation, so a queued launch could never start and nothing could ever
    /// release it. Queued work takes the oldest idle reservation instead.
    @Test func queuedWorkTakesAnIdleReservationAndGivesItBackWhenTheAgentWorks() async throws {
        let (fixture, backend, store) = try fixture()
        let idle = store.spawn(id: "idle", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { idle.isProcessStarted }
        try makeIdleHolder(idle, backend: backend)

        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        queued.startBackgroundBackendIfNeeded()
        #expect(queued.agentQueuePosition == 1)
        try await waitForPuckState { queued.isProcessStarted }
        #expect(store.agentAdmission.running == [queued.id])
        #expect(queued.agentQueuePosition == nil)
        // Yielding is not termination: the idle command keeps its pane.
        #expect(backend.hasSession(named: idle.tmuxSessionName))
        #expect(idle.status != .closed)

        idle.status = .executing
        store.adoptObservedAgentActivity(id: idle.id)
        #expect(store.agentAdmission.running.contains(idle.id))
    }

    @Test func idleReservationsAreKeptWhileNothingIsQueued() async throws {
        let (fixture, backend, store) = try fixture()
        let idle = store.spawn(id: "idle", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { idle.isProcessStarted }
        try makeIdleHolder(idle, backend: backend)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.agentAdmission.running == [idle.id])
        #expect(store.agentAdmission.queuedIDs.isEmpty)
    }

    @Test func parkedFrozenAndBusyCommandsNeverYieldToTheQueue() async throws {
        let (fixture, backend, store) = try fixture()
        store.maximumConcurrentAgents = 2
        let parked = store.spawn(id: "parked", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { parked.isProcessStarted }
        try makeIdleHolder(parked, backend: backend)
        try store.suspend(id: parked.id)
        let busy = store.spawn(id: "busy", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { busy.isProcessStarted }
        busy.status = .executing
        busy.admissionProcessIdentity = AgentProcessIdentity(pid: 2_000_001, startSeconds: 1, startMicroseconds: 2)
        busy.admissionProcessProbe = { _, _ in .unknown }
        busy.lastFreezeInteractionAt = Date().addingTimeInterval(-600)

        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        queued.startBackgroundBackendIfNeeded()
        #expect(queued.agentQueuePosition == 1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!queued.isProcessStarted)
        #expect(store.agentAdmission.running == [parked.id, busy.id])
    }

    @Test func interactionGivesAYieldedReservationBackWithoutWaitingForObservation() async throws {
        let (fixture, backend, store) = try fixture()
        let idle = store.spawn(id: "idle", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { idle.isProcessStarted }
        try makeIdleHolder(idle, backend: backend)
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        queued.startBackgroundBackendIfNeeded()
        try await waitForPuckState { queued.isProcessStarted }
        #expect(store.agentAdmission.running == [queued.id])

        store.adoptAgentReservationForInteraction(id: idle.id)
        #expect(store.agentAdmission.running.contains(idle.id))
    }

    @Test func restoreCountsBusyCommandsAndLeavesIdleRowsWithoutAReservation() async throws {
        let (fixture, _, store) = try fixture()
        let identity = try #require(AgentProcessSample.read(pid: ProcessInfo.processInfo.processIdentifier)?.identity)
        fixture.persistence.save([
            SessionSnapshot(id: "idle-restored", tmuxSessionName: "banyan-idle-restored", title: "Idle", reportedTitle: nil,
                cwd: fixture.project.path, command: "synthetic-agent", status: .needInput, tone: .neutral,
                agentSlotReserved: true, agentSlotPaneIdentity: identity, createdAt: Date(), updatedAt: Date()),
            SessionSnapshot(id: "busy-restored", tmuxSessionName: "banyan-busy-restored", title: "Busy", reportedTitle: nil,
                cwd: fixture.project.path, command: "synthetic-agent", status: .executing, tone: .neutral,
                agentSlotReserved: true, agentSlotPaneIdentity: identity, createdAt: Date(), updatedAt: Date()),
        ])
        store.loadPersistedSessionsIfNeeded()
        #expect(store.agentAdmission.running == ["busy-restored"])
    }

    /// A quiet, verified-idle command with a live recorded identity: exactly what
    /// the admission layer is allowed to take a reservation away from.
    private func makeIdleHolder(_ session: TerminalSession, backend: AdmissionTerminalBackend) throws {
        session.admissionProcessIdentity = AgentProcessIdentity(pid: 2_000_000, startSeconds: 1, startMicroseconds: 2)
        session.admissionProcessProbe = { _, _ in .unknown }
        session.status = .needInput
        session.lastFreezeInteractionAt = Date().addingTimeInterval(-600)
        backend.paneLastActivityAt = Date().addingTimeInterval(-600)
    }

    @Test func closingDuringAsyncLaunchCannotReleaseBeforeTheLateProcessIsRemoved() async throws {
        let (fixture, backend, store) = try fixture()
        let gate = DispatchSemaphore(value: 0)
        backend.launchGate = gate
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { backend.started.count == 1 }
        first.admissionProcessProbe = { _, _ in .exited }
        let second = store.spawn(id: "second", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try store.close(id: first.id)
        #expect(store.agentAdmission.running == [first.id])
        #expect(second.agentQueuePosition == 1)
        gate.signal()
        try await waitForPuckState { backend.started.count == 2 }
        #expect(!backend.hasSession(named: first.tmuxSessionName))
        gate.signal()
        try await waitForPuckState { second.isProcessStarted }
        #expect(store.agentAdmission.running == [second.id])
    }

    @Test func failedAndDeniedInspectionNeverTurnsSuccessfulUninspectedLaunchIntoFreeCapacity() async throws {
        let (fixture, backend, store) = try fixture()
        backend.omitPane = true
        backend.inspectionDenied = true
        let first = store.spawn(id: "uninspected", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        #expect(first.admissionPanePID == nil && first.admissionProcessIdentity == nil)
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        backend.killSession(named: first.tmuxSessionName)
        store.reconcileAgentAdmission(id: first.id)
        try await waitForPuckState { first.admissionInspectionError != nil }
        #expect(store.agentAdmission.running == [first.id])
        #expect(queued.agentQueuePosition == 1)
        backend.inspectionDenied = false // Even known pane absence cannot invent an uncaptured process identity.
        store.reconcileAgentAdmission(id: first.id)
        try await Task.sleep(for: .milliseconds(25))
        #expect(store.agentAdmission.running == [first.id])
    }

    @Test func providerExitAndResumeUseMatchingIdentitiesAndReserveBeforeRetry() async throws {
        let (fixture, _, store) = try fixture()
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        let identity = AgentProcessIdentity(pid: 2_000_000, startSeconds: 1, startMicroseconds: 2)
        first.admissionProcessProbe = { _, _ in .unknown }
        store.recordAgentProviderIdentity(id: first.id, identity: identity)
        let oldWatch = try #require(first.admissionWatchKey)
        store.confirmAgentProviderExit(id: first.id, identity: identity)
        #expect(store.agentAdmission.running == [first.id])
        first.admissionProcessProbe = { _, _ in .exited }
        store.confirmAgentProviderExit(id: first.id, identity: identity)
        #expect(store.agentAdmission.running.isEmpty)
        store.agentAdmission.adopt("other")
        var injected = false
        #expect(!store.requestAgentAdmission(id: first.id, retry: { injected = true }))
        #expect(!injected)
        #expect(first.agentQueuePosition == 1)
        store.confirmAgentProviderExit(id: first.id, identity: identity) // Late old-provider callback.
        #expect(store.agentAdmission.running == ["other"])
        store.agentAdmission.release("other")
        #expect(injected && store.agentAdmission.running == [first.id])
        let replacement = AgentProcessIdentity(pid: 2_000_001, startSeconds: 3, startMicroseconds: 4)
        first.admissionProcessProbe = { _, _ in .unknown }
        let oldGeneration = first.admissionGeneration
        store.recordAgentProviderIdentity(id: first.id, identity: replacement)
        #expect(first.admissionGeneration != oldGeneration)
        store.noteAgentAdmissionProcessExit(key: oldWatch)
        store.confirmAgentProviderExit(id: first.id, identity: identity)
        #expect(store.agentAdmission.running == [first.id])
        #expect(first.admissionProviderIdentity == replacement)
    }

    @Test func restoredCLIReservationSurvivesUnavailableTmuxListing() async throws {
        let (fixture, _, store) = try fixture()
        // This fixture's own process supplies a real inspectable identity; it
        // is observed only, never signalled or treated as a teardown target.
        let identity = try #require(AgentProcessSample.read(pid: ProcessInfo.processInfo.processIdentifier)?.identity)
        fixture.persistence.save([SessionSnapshot(id: "uncertain-restored", tmuxSessionName: "banyan-uncertain-restored",
            title: "Synthetic reserved command", reportedTitle: nil, cwd: fixture.project.path, command: "synthetic-agent",
            status: .failed, tone: .neutral, agentSlotReserved: true, agentSlotPaneIdentity: identity,
            createdAt: Date(), updatedAt: Date())])
        store.loadPersistedSessionsIfNeeded()
        #expect(store.agentAdmission.running == ["uncertain-restored"])
        let queued = store.spawn(id: "queued", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await Task.sleep(for: .milliseconds(25))
        #expect(queued.agentQueuePosition == 1 && store.agentAdmission.running == ["uncertain-restored"])
    }

    @Test func unavailableFolderNeverConsumesAnUnusedLaunchReservation() async throws {
        let (fixture, backend, store) = try fixture()
        let missing = fixture.root.appendingPathComponent("missing-project")
        let denied = TerminalSession(id: "missing", title: "Missing", cwd: missing.path, command: "synthetic-agent",
            theme: .system, tmuxBackend: backend, telemetry: store.telemetry, host: store.host)
        store.configureAgentAdmission(denied)
        denied.startBackingSessionInBackground()
        #expect(denied.status == .failed && store.agentAdmission.running.isEmpty)
        denied.start()
        #expect(store.agentAdmission.running.isEmpty && backend.started.isEmpty)
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        first.admissionProcessProbe = { _, _ in .exited }
        let folder = fixture.root.appendingPathComponent("queued-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let queued = store.spawn(id: "queued", cwd: folder.path, command: "synthetic-agent", select: false)
        #expect(queued.agentQueuePosition == 1)
        try FileManager.default.removeItem(at: folder)
        backend.killSession(named: first.tmuxSessionName)
        store.reconcileAgentAdmission(id: first.id)
        try await waitForPuckState { queued.status == .failed && store.agentAdmission.running.isEmpty }
        #expect(backend.started == [first.tmuxSessionName])
    }

    @Test func puckTurnsShareTerminalBudgetAndWaitForActualCompletion() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let backend = AdmissionTerminalBackend()
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        let store = fixture.makeStore(sessionBackend: backend, freezePreferences: defaults)
        store.maximumConcurrentAgents = 1
        let first = store.spawn(id: "terminal", cwd: fixture.project.path, command: "synthetic-agent", select: false)
        try await waitForPuckState { first.isProcessStarted }
        first.admissionProcessProbe = { _, _ in .exited }
        let puck = try await store.createPuckSession(binding: .init(provider: "codex"), cwd: fixture.project.path, id: "puck", select: false)
        let turn = Task { try await puck.startTurn("Synthetic turn") }
        try await waitForPuckState { puck.agentQueuePosition == 1 }
        #expect(daemon.turns.isEmpty)
        backend.killSession(named: first.tmuxSessionName)
        store.reconcileAgentAdmission(id: first.id)
        try await turn.value
        #expect(daemon.turns.count == 1)
        #expect(store.agentAdmission.running == [puck.id])
        puck.apply(summary: try daemon.get(puck.id).with(position: "parked"))
        #expect(store.agentAdmission.running == [puck.id])
        puck.apply(summary: try daemon.get(puck.id).with(position: "idle"))
        #expect(store.agentAdmission.running.isEmpty)
    }
    @Test func puckCompletionBeforeTurnReplyReleasesAndHiddenRowsKeepAccountingWatch() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let defaults = UserDefaults(suiteName: "banyan-admission-\(UUID().uuidString)")!
        let store = fixture.makeStore(freezePreferences: defaults)
        store.maximumConcurrentAgents = 1
        defer { store.stopPuckObservation() }
        let puck = try await store.createPuckSession(binding: .init(provider: "codex"), cwd: fixture.project.path, id: "short", select: false)
        let gate = daemon.holdTurns()
        let turn = Task { try await puck.startTurn("Finish before RPC reply") }
        defer { gate.signal() }
        try await waitForPuckState { daemon.turns.count == 1 && daemon.watchCount == 1 }
        let idle = try daemon.get(puck.id).with(position: "idle")
        daemon.put(idle)
        daemon.publishWatch(.snapshot([idle]))
        try await waitForPuckState { puck.position == "idle" }
        #expect(store.agentAdmission.running == [puck.id])
        gate.signal()
        try await turn.value
        #expect(store.agentAdmission.running.isEmpty)
        // A parked/closed/removed row must still receive summary accounting.
        for action in ["park", "close", "remove"] {
            let running = idle.with(position: "running")
            daemon.put(running)
            daemon.publishWatch(.snapshot([running]))
            try await waitForPuckState { store.agentAdmission.running.contains(puck.id) }
            switch action {
            case "park": try store.suspend(id: puck.id)
            case "close": try store.close(id: puck.id)
            default: try store.remove(id: puck.id)
            }
            daemon.put(idle)
            daemon.publishWatch(.snapshot([idle]))
            try await waitForPuckState { store.agentAdmission.running.isEmpty }
        }
    }

}
