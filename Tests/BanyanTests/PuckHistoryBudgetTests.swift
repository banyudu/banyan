import BanyanCore
import Foundation
import Testing
@testable import Banyan

@Suite(.serialized)
@MainActor
struct PuckHistoryBudgetTests {
    @Test func dashboardSummariesDoNotLoadSavedTranscripts() throws {
        let daemon = HistoryBudgetDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summaries = (0..<300).map { index in
            puckSummary(id: "history-session-\(index)", cwd: fixture.project.path, historyItems: 10_000)
        }
        for summary in summaries { daemon.base.put(summary) }
        store.applyPuckSummaries(summaries)
        #expect(store.sessions.count == 300)
        #expect(daemon.historyRequests.isEmpty)
        #expect(summaries.allSatisfy { !daemon.base.isFollowed($0.id) })
        #expect(store.sessions.compactMap { $0 as? PuckSession }.allSatisfy { $0.historyItems.isEmpty && $0.events.isEmpty })
    }

    @Test func olderPagesUseOpaqueCursorMergeStableIDsAndReturnToLatest() async throws {
        let daemon = HistoryBudgetDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(id: "paged-session", cwd: fixture.project.path)
        daemon.base.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        session.startFollowing()
        defer { session.stopFollowing() }
        try await waitForPuckState { session.followState == .following }
        daemon.base.push(.history(historyBudgetPage([6, 5, 4], cursor: "opaque:before-four")), to: summary.id)
        try await waitForPuckState { session.nextHistoryCursor == "opaque:before-four" }
        daemon.putPage(historyBudgetPage([4, 3, 2], cursor: "opaque:before-two"), cursor: "opaque:before-four")
        session.loadOlderHistory()
        try await waitForPuckState { !session.historyLoading && session.nextHistoryCursor == "opaque:before-two" }
        #expect(session.historyItems.map(\.id) == ["item-2", "item-3", "item-4", "item-5", "item-6"])
        #expect(daemon.historyRequests.first?.cursor == "opaque:before-four")
        #expect(daemon.historyRequests.first?.limit == 50)

        // Live refreshes must leave the page the user is reading in place.
        daemon.base.push(.history(historyBudgetPage([8, 7, 6], cursor: "latest-cursor")), to: summary.id)
        try await Task.sleep(for: .milliseconds(40))
        #expect(session.historyItems.first?.id == "item-2")
        daemon.putPage(historyBudgetPage([8, 7, 6], cursor: "latest-cursor"), cursor: nil)
        session.loadLatestHistory()
        try await waitForPuckState { !session.historyLoading && session.nextHistoryCursor == "latest-cursor" }
        #expect(session.historyItems.map(\.id) == ["item-6", "item-7", "item-8"])
        #expect(daemon.historyRequests.last?.cursor == nil)
        session.stopFollowing()
        #expect(session.historyItems.isEmpty)
        #expect(session.events.isEmpty)
        #expect(daemon.base.turns.isEmpty)
    }

    @Test func visitingManyLargeTranscriptsEvictsGlobally() async throws {
        let daemon = HistoryBudgetDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summaries = (0..<12).map { puckSummary(id: "budget-session-\($0)", cwd: fixture.project.path) }
        for summary in summaries { daemon.base.put(summary) }
        store.applyPuckSummaries(summaries)
        let sessions = store.sessions.compactMap { $0 as? PuckSession }
        defer { sessions.forEach { $0.stopFollowing() } }
        for session in sessions {
            session.startFollowing()
            try await waitForPuckState { session.followState == .following }
            let items = (0..<2).map {
                PuckHistoryItem(id: "\(session.id)-\($0)", kind: "assistant", text: String(repeating: "x", count: 700_000))
            }
            daemon.base.push(.history(PuckHistoryPage(session: session.id, source: "display", items: items, nextCursor: "older")), to: session.id)
            try await waitForPuckState { session.historyItems.count == 2 }
            let totalBytes = sessions.flatMap(\.historyItems).reduce(0) { $0 + $1.text.utf8.count + $1.id.utf8.count + 128 }
            #expect(totalBytes <= 4 * 1_048_576)
            #expect(session.historyItems.count <= 200)
        }
        #expect(sessions.filter { !$0.historyItems.isEmpty }.count <= 2)
        #expect(sessions.first?.historyItems.isEmpty == true)
        #expect(sessions.last?.historyItems.count == 2)
    }

    @Test func detachedViewDoesNotRepopulateCacheFromAnInflightPage() async throws {
        let daemon = HistoryBudgetDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore()
        let summary = puckSummary(id: "detached-history-session", cwd: fixture.project.path)
        daemon.base.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        session.startFollowing()
        defer { session.stopFollowing() }
        try await waitForPuckState { session.followState == .following }
        daemon.base.push(.history(historyBudgetPage([6, 5, 4], cursor: "held-page")), to: summary.id)
        try await waitForPuckState { session.nextHistoryCursor == "held-page" }
        daemon.putPage(historyBudgetPage([3, 2, 1], cursor: nil), cursor: "held-page")
        let release = daemon.holdHistory()
        defer { release.signal() }
        session.loadOlderHistory()
        try await waitForPuckState { daemon.historyRequests.count == 1 }
        session.stopFollowing()
        #expect(session.historyItems.isEmpty)
        release.signal()
        try await waitForPuckState { daemon.historyReturns == 1 }
        try await Task.sleep(for: .milliseconds(40))
        try await waitForPuckState { !session.historyLoading }
        #expect(session.followState == .stopped)
        #expect(session.historyItems.isEmpty)
        #expect(session.nextHistoryCursor == nil)
    }

    @Test(arguments: ["server", "notSubmitted", "ambiguousUnavailable"])
    func puckSubmissionCertaintyControlsAdmissionReservation(failureKind: String) async throws {
        let error: PuckDaemonError
        switch failureKind {
        case "server": error = .server(PuckServerError(code: "busy", message: "Fixture refused this turn"))
        case "notSubmitted": error = .notSubmitted("SDK request queue is full; retry shortly")
        default: error = .unavailable("Socket closed before an acknowledgement")
        }
        let daemon = HistoryBudgetDaemon(turnError: error)
        let fixture = try PuckStoreFixture(daemon: daemon)
        let defaults = try #require(UserDefaults(suiteName: "sdk-submission-\(UUID().uuidString)"))
        let store = fixture.makeStore(freezePreferences: defaults)
        store.maximumConcurrentAgents = 1
        let summary = puckSummary(id: "rejected-turn", cwd: fixture.project.path)
        daemon.base.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        session.onAdmissionTurnStarting = nil
        defer { store.agentAdmission.release(session.id); store.agentAdmission.release("next-slot") }
        do {
            try await session.startTurn("A rejected fixture turn")
            Issue.record("The rejected submission was reported as accepted")
        } catch let failure as PuckDaemonError {
            switch (failureKind, failure) {
            case ("server", .server(let data)): #expect(data.code == "busy")
            case ("notSubmitted", .notSubmitted): break
            case ("ambiguousUnavailable", .unavailable): break
            default: Issue.record("Submission error kind changed: \(failure)")
            }
        }
        let shouldRelease = failureKind != "ambiguousUnavailable"
        #expect(store.agentAdmission.running.contains(session.id) == !shouldRelease)
        #expect(store.agentAdmission.acquireImmediately("next-slot") == shouldRelease)
        #expect(!session.admissionTurnInFlight)
        #expect(daemon.turnAttempts == 1)
    }

    @Test func puckQueuedSubmissionCancellationReleasesReservationWithoutDelivery() async throws {
        let daemon = HistoryBudgetDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let defaults = try #require(UserDefaults(suiteName: "sdk-submission-\(UUID().uuidString)"))
        let store = fixture.makeStore(freezePreferences: defaults)
        store.maximumConcurrentAgents = 1
        let summary = puckSummary(id: "queued-cancel-turn", cwd: fixture.project.path)
        daemon.base.put(summary)
        store.applyPuckSummaries([summary])
        let session = try #require(store.sessions.first as? PuckSession)
        session.onAdmissionTurnStarting = nil
        let state = AdmissionBackgroundState()
        let release = DispatchSemaphore(value: 0)
        defer {
            for _ in 0..<4 { release.signal() }
            store.agentAdmission.release(session.id)
        }
        let blockers = (0..<4).map { _ in
            Task {
                try await PuckBackgroundIO.run {
                    state.start()
                    _ = release.wait(timeout: .now() + 10)
                    return 1
                }
            }
        }
        try await waitForPuckState { state.started == 4 }
        let submission = Task { try await session.startTurn("Cancel before RPC delivery") }
        defer { submission.cancel() }
        try await waitForPuckState { session.admissionTurnInFlight && store.agentAdmission.running.contains(session.id) }
        try await Task.sleep(for: .milliseconds(100))
        submission.cancel()
        do {
            try await submission.value
            Issue.record("Cancelled queued submission was reported as accepted")
        } catch is CancellationError {}
        #expect(store.agentAdmission.running.isEmpty)
        #expect(!session.admissionTurnInFlight)
        #expect(daemon.turnAttempts == 0)
        for _ in 0..<4 { release.signal() }
        for blocker in blockers { _ = try await blocker.value }
        #expect(daemon.turnAttempts == 0)
        #expect(daemon.base.turns.isEmpty)
    }
}

private final class AdmissionBackgroundState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var started: Int { lock.withLock { count } }
    func start() { lock.withLock { count += 1 } }
}

private func historyBudgetPage(_ ids: [Int], cursor: String?) -> PuckHistoryPage {
    PuckHistoryPage(session: "paged-session", source: "display", items: ids.map {
        PuckHistoryItem(id: "item-\($0)", kind: "assistant", text: "message \($0)")
    }, nextCursor: cursor)
}

private final class HistoryBudgetDaemon: PuckDaemonService, @unchecked Sendable {
    struct HistoryRequest { let session: String; let cursor: String?; let limit: Int }
    let base = FakePuckDaemon()
    private let lock = NSLock()
    private var pages: [String: PuckHistoryPage] = [:]
    private var requests: [HistoryRequest] = []
    private var historyGate: DispatchSemaphore?
    private var returnedPages = 0
    private let turnError: PuckDaemonError?
    private var attemptedTurns = 0
    init(turnError: PuckDaemonError? = nil) { self.turnError = turnError }
    var turnAttempts: Int { lock.withLock { attemptedTurns } }
    var historyReturns: Int { lock.withLock { returnedPages } }
    var historyRequests: [HistoryRequest] { lock.withLock { requests } }
    func putPage(_ page: PuckHistoryPage, cursor: String?) { lock.withLock { pages[cursor ?? "<latest>"] = page } }
    func holdHistory() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { historyGate = gate }
        return gate
    }
    func history(_ id: String, cursor: String?, limit: Int) throws -> PuckHistoryPage {
        let (page, gate) = try lock.withLock {
            requests.append(HistoryRequest(session: id, cursor: cursor, limit: limit))
            guard let page = pages[cursor ?? "<latest>"] else { throw PuckDaemonError.rejected("missing fixture page") }
            return (page, historyGate)
        }
        gate?.wait()
        lock.withLock { returnedPages += 1 }
        return page
    }
    func list() throws -> [PuckSessionSummary] { try base.list() }
    func get(_ id: String) throws -> PuckSessionSummary { try base.get(id) }
    func create(id: String, provider: String, account: String?, model: String?, workspace: String) throws -> PuckSessionSummary {
        try base.create(id: id, provider: provider, account: account, model: model, workspace: workspace)
    }
    func turn(_ id: String, prompt: String) throws {
        lock.withLock { attemptedTurns += 1 }
        if let turnError { throw turnError }
        try base.turn(id, prompt: prompt)
    }
    func decide(_ id: String, callID: String, decision: String) throws { try base.decide(id, callID: callID, decision: decision) }
    func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) throws { try base.answer(id, callID: callID, selections: selections) }
    func plan(_ id: String) throws -> String? { try base.plan(id) }
    func reject(_ id: String, callID: String, reason: String) throws { try base.reject(id, callID: callID, reason: reason) }
    func watch() -> any PuckDaemonObservation { base.watch() }
    func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error> { base.follow(id) }
}
