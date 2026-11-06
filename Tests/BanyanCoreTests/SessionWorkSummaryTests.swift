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

    private func phasedOverview(_ jobs: [[String: Any]]) throws -> WorkitOverview {
        try WorkitOverview.decode(JSONSerialization.data(withJSONObject: [
            "version": 1, "generatedAt": "2026-01-01T00:00:00Z", "total": jobs.count,
            "truncated": false, "jobs": jobs,
        ]))
    }

    private func phasedJob(_ id: String, phase: String, attention: String, group: String,
                           kind: String = "working", label: String = "Working") -> [String: Any] {
        ["id": id, "sessionID": id, "revision": 1, "title": id, "stage": "implementing",
         "group": group, "phase": phase, "attention": attention,
         "display": ["kind": kind, "label": label], "detail": "", "createdAt": "2026-01-01T00:00:00Z",
         "progress": ["passed": 0, "total": 2], "nextAction": "Continue", "evidence": []]
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
        #expect(parent.groupStatuses.map(\.count) == [1, 1, 1, 2])
        #expect(parent.groupStatuses.map(\.label) == ["waiting", "blocked", "verified", "idle"])
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

    @Test func runtimeActivityOverridesWorkingPresentationWithoutCompletingWorkflow() throws {
        for status in [SessionStatus.needInput, .idle, .review, .completed] {
            let nodes = [node("worker", job: "worker", status: status)]
            let feed = try phasedOverview([
                phasedJob("worker", phase: "merged", attention: "watch", group: "working"),
            ])
            for overview in [nil, feed] {
                let entry = try #require(SessionWorkTree.summaries(nodes: nodes, overview: overview)["worker"]?.own)
                #expect(entry.kind == .idle)
                #expect(entry.managed)
                #expect(entry.label.contains(overview == nil ? "workflow unfinished" : "Merged · 0/2 AC"))
                if status == .needInput { #expect(entry.label.hasPrefix("Waiting for input")) }
                #expect(nodes[0].workflow?.state == .working)
                #expect(nodes[0].workflow?.state.permitsClose == false)
            }
        }

        let active = [node("worker", job: "worker", status: .executing)]
        #expect(SessionWorkTree.summaries(nodes: active, overview: nil)["worker"]?.own.kind == .working)
        let blocked = [node("worker", job: "job", status: .needInput)]
        #expect(SessionWorkTree.summaries(nodes: blocked, overview: try overview())["worker"]?.own.kind == .blocked)
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

    @Test func phaseMetadataDrivesFocusAndMergeBoundaryPresentation() throws {
        let nodes = [node("parent"), node("merged", parent: "parent", job: "merged", state: .needsYou),
                     node("proving", parent: "parent", job: "proving", state: .working, status: .executing),
                     node("quiet", parent: "parent", job: "quiet", state: .waiting, status: .executing)]
        let feed = try phasedOverview([
            phasedJob("merged", phase: "merged", attention: "act", group: "needs-you",
                      kind: "blocked", label: "Check merge"),
            phasedJob("proving", phase: "merged", attention: "watch", group: "working"),
            phasedJob("quiet", phase: "pr-open", attention: "watch", group: "waiting"),
        ])
        let result = SessionWorkTree.summaries(nodes: nodes, overview: feed)

        #expect(result["merged"]?.own.phase == .merged)
        #expect(result["merged"]?.own.focusLane == .act)
        #expect(result["merged"]?.own.label == "Merged · 0/2 AC")
        #expect(result["proving"]?.own.focusLane == .watch)
        #expect(result["parent"]?.groupLabel == "1 needs you · 1 PR open · 1 merged")
        #expect(result["parent"]?.groupStatuses.map(\.label) == ["needs you", "PR open", "merged"])

        let askingNodes = [node("asking", job: "asking", status: .asking)]
        let askingFeed = try phasedOverview([
            phasedJob("asking", phase: "implementation", attention: "watch", group: "working"),
        ])
        #expect(SessionWorkTree.summaries(nodes: askingNodes, overview: askingFeed)["asking"]?.own.focusLane == .act)
    }

    @Test func unmanagedStatusesResolveToFocusLanes() {
        let nodes = [
            node("executing", status: .executing),
            node("idle", status: .idle),
            node("input", status: .needInput),
            node("asking", status: .asking),
            node("review", status: .review),
            node("failed", status: .failed),
            node("completed", status: .completed),
        ]
        let result = SessionWorkTree.summaries(nodes: nodes, overview: nil)

        #expect(result["executing"]?.own.focusLane == .watch)
        #expect(result["idle"]?.own.focusLane == .watch)
        #expect(result["input"]?.own.focusLane == .act)
        #expect(result["asking"]?.own.focusLane == .act)
        #expect(result["review"]?.own.focusLane == .act)
        #expect(result["failed"]?.own.focusLane == .act)
        #expect(result["completed"]?.own.focusLane == .settled)
    }

    @Test func finishedTerminalStatusOverridesAStaleWorkingJob() throws {
        let nodes = [node("done", job: "job", state: .working, status: .completed)]
        let feed = try phasedOverview([
            phasedJob("done", phase: "implementation", attention: "watch", group: "working"),
        ])

        #expect(SessionWorkTree.summaries(nodes: nodes, overview: feed)["done"]?.own.focusLane == .settled)
    }

    @Test func externallyWaitingJobStaysQuietDespiteAStaleTerminalPrompt() throws {
        let nodes = [node("waiting", job: "waiting", state: .waiting, status: .needInput)]
        let feed = try phasedOverview([
            phasedJob("waiting", phase: "pr-open", attention: "watch", group: "waiting",
                      kind: "waiting", label: "Waiting for CI"),
        ])

        #expect(SessionWorkTree.summaries(nodes: nodes, overview: feed)["waiting"]?.own.focusLane == .watch)
    }

    @Test func externallyWaitingJobStillShowsWhenWorkitNeedsAct() throws {
        let nodes = [node("waiting", job: "waiting", state: .waiting, status: .executing)]
        let feed = try phasedOverview([
            phasedJob("waiting", phase: "pr-open", attention: "act", group: "waiting",
                      kind: "blocked", label: "Check CI"),
        ])

        #expect(SessionWorkTree.summaries(nodes: nodes, overview: feed)["waiting"]?.own.focusLane == .act)
    }

    @Test func activeTerminalWorkOverridesSettledWorkitState() throws {
        let nodes = [node("verified", job: "verified", state: .verified, status: .executing)]
        let feed = try phasedOverview([
            phasedJob("verified", phase: "verified", attention: "settled", group: "verified",
                      kind: "verified", label: "Verified"),
        ])

        #expect(SessionWorkTree.summaries(nodes: nodes, overview: feed)["verified"]?.own.focusLane == .watch)
    }

    @Test func activeTerminalWorkStillShowsWhenWorkitNeedsAct() throws {
        let nodes = [node("held", job: "held", state: .needsYou, status: .executing)]
        let feed = try phasedOverview([
            phasedJob("held", phase: "pr-open", attention: "act", group: "needs-you",
                      kind: "blocked", label: "Held"),
        ])

        #expect(SessionWorkTree.summaries(nodes: nodes, overview: feed)["held"]?.own.focusLane == .act)
    }
}
