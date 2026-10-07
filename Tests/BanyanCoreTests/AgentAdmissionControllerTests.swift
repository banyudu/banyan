import Foundation
import Testing
@testable import BanyanCore

@MainActor
@Suite struct AgentAdmissionTests {
    @Test func fifoReservationsDeduplicateAndDoNotPreemptExistingWork() {
        let pool = AgentAdmissionController(limit: 2)
        var started: [String] = []
        #expect(pool.request("a", start: {}) == true)
        #expect(pool.request("b", start: {}) == true)
        #expect(!pool.request("c", start: { started.append("c") }))
        #expect(!pool.request("c", start: { Issue.record("duplicate launch") }))
        #expect(!pool.request("d", start: { started.append("d") }))
        #expect(pool.queuedIDs == ["c", "d"])
        pool.setLimit(1)
        pool.release("a")
        #expect(started.isEmpty)
        pool.release("b")
        #expect(started == ["c"])
        #expect(pool.running == ["c"])
        pool.release("c")
        #expect(started == ["c", "d"])
    }

    @Test func restoredOverBudgetWorkBlocksNewLaunchesUntilBelowCap() {
        let pool = AgentAdmissionController(limit: 1)
        for id in ["restored", "parked", "frozen"] { pool.adopt(id) }
        var started = false
        #expect(!pool.request("new", start: { started = true }))
        pool.release("restored")
        pool.release("parked")
        #expect(!started)
        #expect(pool.running == ["frozen"])
        pool.release("frozen")
        #expect(started)
        #expect(pool.running == ["new"])
    }

    @Test func priorityAndCancellationAreExplicitAndFair() {
        let pool = AgentAdmissionController(limit: 1)
        pool.adopt("busy")
        var started: [String] = []
        for id in ["first", "cancelled", "next", "last"] {
            #expect(!pool.request(id, start: { started.append(id) }))
        }
        pool.cancel("cancelled")
        pool.prioritize("next")
        #expect(pool.queuedIDs == ["next", "first", "last"])
        for id in ["busy", "next", "first"] { pool.release(id) }
        #expect(started == ["next", "first", "last"])
    }

    @Test func cancelledAsyncWaitersCannotLaunchOrStealSuccessorCapacity() async throws {
        let pool = AgentAdmissionController(limit: 1)
        pool.adopt("busy")
        let cancelled = Task { try await pool.acquire("cancelled") }
        try await admissionEventually { pool.position(of: "cancelled") == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        try await admissionEventually { pool.queuedIDs.isEmpty }
        let next = Task { try await pool.acquire("next") }
        try await admissionEventually { pool.queuedIDs == ["next"] }
        pool.release("busy")
        try await next.value
        #expect(pool.running == ["next"])
    }

    @Test func concurrentFleetNeverExceedsReservedCapacity() async throws {
        let pool = AgentAdmissionController(limit: 3)
        var live = 0, peak = 0, completed = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask { @MainActor in
                    let id = "synthetic-\(index)"
                    try await pool.acquire(id)
                    live += 1
                    peak = max(peak, live)
                    for _ in 0..<5 { await Task.yield() }
                    live -= 1
                    completed += 1
                    pool.release(id)
                }
            }
            try await group.waitForAll()
        }
        #expect(peak == 3)
        #expect(completed == 30)
        #expect(pool.running.isEmpty && pool.queuedIDs.isEmpty)
    }

    @Test func queuedAndCancelledLaunchIntentsRoundTripThroughSQLiteAndJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = SessionDatabase(databaseURL: root.appendingPathComponent("state.sqlite"),
            legacyJSONURL: root.appendingPathComponent("legacy.json"))
        let snapshots = [false, true].enumerated().map { index, cancelled in
            SessionSnapshot(id: "queued-\(index)", tmuxSessionName: "banyan-queued-\(index)", title: "Synthetic",
                reportedTitle: nil, cwd: "/tmp/project", command: "synthetic-agent", status: .running, tone: .blue,
                agentLaunchQueue: .init(requestedAt: Date(timeIntervalSince1970: 100), cancelled: cancelled, purpose: .deepResume),
                agentSlotReserved: cancelled,
                agentSlotPaneIdentity: .init(pid: 1234, startSeconds: 1, startMicroseconds: 2),
                agentSlotProviderIdentity: .init(pid: 1235, startSeconds: 3, startMicroseconds: 4),
                createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
        }
        database.save(snapshots)
        #expect(database.load() == snapshots)
        #expect(try JSONDecoder().decode([SessionSnapshot].self, from: JSONEncoder().encode(snapshots)) == snapshots)
        #expect(snapshots[0].updating(status: .idle).agentLaunchQueue == snapshots[0].agentLaunchQueue)
    }
}

@MainActor
func admissionEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw AdmissionTestTimeout() }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private struct AdmissionTestTimeout: Error {}
