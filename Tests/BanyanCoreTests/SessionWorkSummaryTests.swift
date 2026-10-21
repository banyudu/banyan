import Foundation
import Testing
@testable import BanyanCore

@Suite struct SessionWorkSummaryTests {
    private func node(_ id: String, parent: String? = nil, job: String? = nil,
                      revision: Int = 1, state: SessionWorkflow.State = .working,
                      status: SessionStatus = .needInput, background: Bool = false) -> SessionWorkNode {
        .init(id: id, parentID: parent, title: id, status: status,
              workflow: job.map { .init(owner: "workit", jobID: $0, revision: revision, state: state) }, background: background)
    }
    private func overview(session: String = "worker", revision: Int = 1, kind: String? = "blocked", stop: String = "Tool timed out") throws -> WorkitOverview {
        var job: [String: Any] = ["id": "job", "sessionID": session, "revision": revision, "title": "Example issue", "stage": "needs-you", "group": "needs-you", "detail": "Hold retained; PR merged", "createdAt": "2026-01-01T00:00:00Z", "progress": ["passed": 0, "total": 2], "nextAction": "Repair the tool and inspect the receipt", "evidence": []]
        if let kind { job["display"] = ["kind": kind, "label": "Tool error"]; job["stopReason"] = stop }
        return try WorkitOverview.decode(JSONSerialization.data(withJSONObject: ["version": 1, "generatedAt": "2026-01-01T00:00:00Z", "total": 1, "truncated": false, "jobs": [job]]))
    }

    @Test func nestedBackgroundWorkRemainsCountedAndIdleIsNotCompletion() throws {
        let nodes = [node("parent"), node("worker", parent: "parent", job: "job", state: .needsYou, background: true),
            node("review", parent: "worker", job: "review", state: .waiting),
            node("done", parent: "parent", job: "done", state: .verified), node("idle", parent: "parent"),
            node("shell", parent: "parent", status: .running),
            node("closed", parent: "parent", status: .closed)]
        let result = SessionWorkTree.summaries(nodes: nodes, overview: try overview())
        let parent = try #require(result["parent"])
        #expect(parent.descendants.count == 5)
        #expect(parent.groupLabel == "1 waiting · 1 blocked · 1 verified · 2 idle")
        #expect(result["worker"]?.own.label == "Tool error")
        #expect(result["worker"]?.own.detail == "Tool timed out")
        #expect(result["worker"]?.own.background == true)
        #expect(result["idle"]?.own.kind == .idle)
        #expect(result["shell"]?.own.kind == .idle)
        #expect(result["parent"]?.own.managed == false)
    }

    @Test func staleAndMismatchedOverviewCannotReplaceWorkflowStatus() throws {
        let nodes = [node("worker", job: "job", revision: 2, state: .paused)]
        for feed in [try overview(revision: 1), try overview(session: "other", revision: 2)] {
            let entry = try #require(SessionWorkTree.summaries(nodes: nodes, overview: feed)["worker"]?.own)
            #expect(entry.job == nil)
            #expect(entry.label == "Paused")
        }
        let oldFeed = try overview(revision: 2, kind: nil)
        #expect(SessionWorkTree.summaries(nodes: nodes, overview: oldFeed)["worker"]?.own.label == "Paused")
        #expect(throws: (any Error).self) { try overview(stop: String(repeating: "x", count: 1001)) }
    }

    @Test func duplicateJobsAndCyclesCannotInflateGroupCounts() {
        let nodes = [node("parent"), node("worker", parent: "parent", job: "same"),
            node("duplicate", parent: "worker", job: "same"), node("worker", parent: "parent", job: "same")]
        let result = SessionWorkTree.summaries(nodes: nodes, overview: nil)
        #expect(result["parent"]?.descendants.count == 1)
        #expect(result["worker"]?.descendants.isEmpty == true)
        let cycle = SessionWorkTree.summaries(nodes: [node("a", parent: "b"), node("b", parent: "a")], overview: nil)
        #expect(cycle["a"]?.descendants.map(\.id) == ["b"])
        #expect(cycle["b"]?.descendants.map(\.id) == ["a"])
    }
}
