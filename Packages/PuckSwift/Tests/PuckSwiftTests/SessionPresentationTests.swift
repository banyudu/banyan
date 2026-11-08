import Foundation
import Testing
import PuckSwift

@Suite("Session ownership and attention", .serialized)
struct SessionPresentationTests {
    @Test func oldAndUnownedPayloadsRemainDistinct() throws {
        let old = try PuckSessionSummary(sdkSummary())
        #expect(old.presentation == nil)
        #expect(old.agentClass == "worker")
        var value = sdkSummary()
        value["class"] = "cockpit"
        value["parent_session"] = "parent"
        value["subagent_name"] = "research"
        value["presentation"] = ["title": "research", "owner": NSNull(), "attention": []] as [String: Any]
        let unowned = try PuckSessionSummary(value)
        #expect(unowned.presentation?.owner == nil)
        #expect(unowned.presentation?.title == "research")
        #expect(unowned.agentClass == "cockpit")
        #expect(unowned.parentSession == "parent")
        #expect(unowned.subagentName == "research")
    }

    @Test func typedOwnersKeepHistoricalWorkAndActualAsksSeparate() throws {
        var value = presentationSummary(title: "Task", job: false)
        var presentation = value["presentation"] as! [String: Any]
        var owner = presentation["owner"] as! [String: Any]
        owner["is_current"] = false
        presentation["owner"] = owner
        presentation["attention"] = [["scope": "session", "kind": "question", "requires_human": true]]
        value["presentation"] = presentation
        let task = try PuckSessionSummary(value)
        #expect(task.presentation?.owner?.taskID == "task-1")
        #expect(task.presentation?.owner?.attemptID == "attempt-1")
        #expect(task.presentation?.owner?.isCurrent == false)
        #expect(task.presentation?.attention.first?.scope == "session")
        #expect(task.presentation?.attention.first?.requiresHuman == true)
        let job = try PuckSessionSummary(presentationSummary(title: "Job", job: true))
        #expect(job.presentation?.owner?.jobID == "job-1")
        #expect(job.presentation?.owner?.runID == "run-1")
        #expect(job.presentation?.owner?.isLatest == true)
        #expect(job.presentation?.owner?.runRevision == 4)
    }

    @Test func requestBuffersOwnerEventsAlongsideSessionEvents() throws {
        let fixture = try SDKSocketFixture { peer, request in
            for method in ["task.event", "job.event"] {
                try peer.send(["jsonrpc": "2.0", "method": method, "params": ["event": ["kind": "updated"]]])
            }
            try peer.reply(request, result: [:] as [String: Any])
        }
        defer { fixture.stop() }
        let connection = try PuckDaemonConnection(socketPath: fixture.path)
        _ = try connection.request("session.watch")
        #expect(try connection.nextNotification()?["method"] as? String == "task.event")
        #expect(try connection.nextNotification()?["method"] as? String == "job.event")
        #expect(fixture.failures.isEmpty)
    }

    @Test func watchRefreshesOwnerOnlyChangesBufferedEventsLagAndReconnect() async throws {
        let state = PresentationFixtureState()
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "session.watch":
                if state.setPeer(peer) {
                    // This event precedes the watch acknowledgement and must
                    // survive the initial snapshot and presence requests.
                    try peer.send(["jsonrpc": "2.0", "method": "task.event", "params": ["event": ["kind": "state_changed"]]])
                }
                try peer.reply(request, result: ["watching": true])
            case "presence.away": try peer.reply(request, result: ["window_seconds": 300])
            case "presence.active": try peer.reply(request, result: [:] as [String: Any])
            case "session.list":
                let (title, job) = state.listing()
                try peer.reply(request, result: [presentationSummary(title: title, job: job)])
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        let client = PuckDaemonClient(socketPath: fixture.path)
        let watch = client.watch()
        defer { watch.cancel() }
        let consumer = Task {
            for try await update in watch.updates {
                if case .snapshot(let summaries) = update {
                    state.observe(summaries[0].presentation?.title ?? "missing")
                }
            }
        }
        defer { consumer.cancel() }
        try await sdkEventually { state.titles.contains("Task changed") }
        #expect(state.titles.first == "Initial snapshot")
        try state.change(title: "Job renamed", method: "job.event", kind: "job_updated")
        try await sdkEventually { state.titles.contains("Job renamed") }
        try state.change(title: "Recovered after lag", method: "job.event", kind: "lagged")
        try await sdkEventually { state.titles.contains("Recovered after lag") }
        watch.cancel()
        let reconnect = client.watch()
        defer { reconnect.cancel() }
        var iterator = reconnect.updates.makeAsyncIterator()
        let first = try await iterator.next()
        if case .snapshot(let summaries) = first {
            #expect(summaries.first?.presentation?.title == "Recovered after lag")
            #expect(summaries.first?.presentation?.owner?.kind == "job")
        } else { Issue.record("Reconnect did not restore the current projection") }
        #expect(fixture.failures.isEmpty)
    }
}

private func presentationSummary(title: String, job: Bool) -> [String: Any] {
    var summary = sdkSummary()
    summary["class"] = "worker"
    let owner: [String: Any] = job
        ? ["kind": "job", "job_id": "job-1", "run_id": "run-1", "title": title,
           "state": "completed", "revision": 3, "run_revision": 4, "is_latest": true]
        : ["kind": "task", "task_id": "task-1", "attempt_id": "attempt-1", "title": title,
           "state": "ready_for_decision", "attempt_state": "completed", "revision": 2, "is_current": true]
    summary["presentation"] = ["title": title, "owner": owner, "attention": []] as [String: Any]
    return summary
}

private final class PresentationFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: SDKSocketPeer?
    private var listCount = 0
    private var title = "Task changed"
    private var job = false
    private var observed: [String] = []
    var titles: [String] { lock.withLock { observed } }
    func setPeer(_ peer: SDKSocketPeer) -> Bool {
        lock.withLock { let first = self.peer == nil; self.peer = peer; return first }
    }
    func listing() -> (String, Bool) {
        lock.withLock { listCount += 1; return (listCount == 1 ? "Initial snapshot" : title, job) }
    }
    func observe(_ title: String) { lock.withLock { observed.append(title) } }
    func change(title: String, method: String, kind: String) throws {
        let target = lock.withLock { self.title = title; job = true; return peer }
        try target?.send(["jsonrpc": "2.0", "method": method, "params": ["event": ["kind": kind]]])
    }
}
