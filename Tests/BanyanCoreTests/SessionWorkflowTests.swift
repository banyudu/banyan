import Foundation
import Testing
@testable import BanyanCore

@Suite struct SessionWorkflowTests {
    @Test func independentStateAndRevisionChecks() throws {
        let current = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 4, state: .waiting)
        #expect(throws: (any Error).self) {
            try current.replacing(.init(owner: "other", jobID: "job-a", revision: 5, state: .working))
        }
        #expect(throws: (any Error).self) {
            try current.replacing(.init(owner: "workit", jobID: "job-a", revision: 3, state: .working))
        }
        #expect(throws: (any Error).self) {
            try current.replacing(.init(owner: "workit", jobID: "job-a", revision: 4, state: .verified))
        }
        #expect(try current.replacing(current) == current)
        #expect(SessionLifecyclePolicy.statusAfterTerminalExit(currentStatus: .running, hasBackingSession: false, exitCode: 0) == .completed)
        #expect(current.state == .waiting)
        #expect(!current.state.permitsClose)
    }

    @Test func receiptsSurviveRestartAndRejectBlindReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionWorkflowJournal(directory: root)
        var workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 4, state: .waiting,
            wake: .init(id: "wake-a", status: .pending))
        try journal.save(workflow, id: "TASK-123")
        let loaded = try SessionWorkflowJournal(directory: root).load(id: "TASK-123")
        let restored = try #require(loaded)
        #expect(restored == workflow)
        #expect(throws: (any Error).self) { try restored.shouldDeliver(jobID: "job-a", revision: 4, wakeID: "wake-a") }
        #expect(throws: (any Error).self) { try restored.shouldDeliver(jobID: "job-a", revision: 4, wakeID: "different") }
        workflow.wake?.status = .delivered
        #expect(try workflow.shouldDeliver(jobID: "job-a", revision: 4, wakeID: "wake-a") == false)
        #expect(try workflow.shouldDeliver(jobID: "job-a", revision: 4, wakeID: "different"))
        workflow.wake?.status = .notDelivered
        #expect(try workflow.shouldDeliver(jobID: "job-a", revision: 4, wakeID: "wake-a"))
        #expect(throws: (any Error).self) { try workflow.shouldDeliver(jobID: "job-a", revision: 3, wakeID: "wake-a") }
        #expect(try journal.load(id: "legacy-session") == nil)
        #expect(throws: (any Error).self) { try journal.save(workflow, id: "../escape") }
    }

    @Test func busyHumanAndParkedSessionsRefuseWake() {
        for status in [SessionStatus.running, .executing, .subagents, .asking, .needInput, .closed] {
            #expect(!SessionWorkflowPolicy.canWake(status: status, isSuspended: false, isFrozen: false,
                isDeepSuspended: false, hasObservation: true, isAgent: true))
        }
        #expect(!SessionWorkflowPolicy.canWake(status: .idle, isSuspended: true, isFrozen: false,
            isDeepSuspended: false, hasObservation: true, isAgent: true))
        #expect(!SessionWorkflowPolicy.canWake(status: .idle, isSuspended: false, isFrozen: false,
            isDeepSuspended: false, hasObservation: false, isAgent: true))
        #expect(!SessionWorkflowPolicy.canWake(status: .idle, isSuspended: false, isFrozen: false,
            isDeepSuspended: false, hasObservation: true, isAgent: false))
        #expect(SessionWorkflowPolicy.canWake(status: .needInput, isSuspended: false, isFrozen: false,
            isDeepSuspended: false, hasObservation: true, isAgent: true, hasEmptyInput: true))
        #expect(!SessionWorkflowPolicy.canWake(status: .needInput, isSuspended: false, isFrozen: false,
            isDeepSuspended: false, hasObservation: true, isAgent: true, hasHumanPrompt: true, hasEmptyInput: true))
    }

    @Test func emptyInputRequiresKnownCurrentShapeAndNoDraft() {
        #expect(SessionWorkflowPolicy.hasEmptyInput("Task complete\n›\n? for shortcuts"))
        #expect(SessionWorkflowPolicy.hasEmptyInput("Task complete\n❯"))
        #expect(!SessionWorkflowPolicy.hasEmptyInput("Task complete\n› unfinished draft"))
        #expect(!SessionWorkflowPolicy.hasEmptyInput("›\nUnrecognized approval dialog\n1. Yes\n2. No"))
        #expect(!SessionWorkflowPolicy.hasEmptyInput("›\n" + Array(repeating: "output", count: 20).joined(separator: "\n")))
        #expect(SessionWorkflowPolicy.hasEmptyInput("┃\n┃\n┃ Model · Provider\nctrl+p commands"))
        #expect(!SessionWorkflowPolicy.hasEmptyInput("┃\n┃ some draft\n┃ Model · Provider"))
    }

    @Test func recoveryRequiresTheSameMissingOrDeadPane() {
        let dead = TmuxPaneSnapshot(paneID: "%1", rootPID: 42, currentCommand: "codex",
            currentPath: "/tmp/project", isDead: true, isInMode: false)
        let live = TmuxPaneSnapshot(paneID: "%1", rootPID: 42, currentCommand: "codex",
            currentPath: "/tmp/project", isDead: false, isInMode: false)
        let replacement = TmuxPaneSnapshot(paneID: "%2", rootPID: 43, currentCommand: "codex",
            currentPath: "/tmp/project", isDead: true, isInMode: false)
        #expect(SessionWorkflowPolicy.canRecover(observed: .absent, current: .absent))
        #expect(SessionWorkflowPolicy.canRecover(observed: .present(dead), current: .present(dead)))
        #expect(!SessionWorkflowPolicy.canRecover(observed: .absent, current: .present(live)))
        #expect(!SessionWorkflowPolicy.canRecover(observed: .present(dead), current: .present(live)))
        #expect(!SessionWorkflowPolicy.canRecover(observed: .present(dead), current: .present(replacement)))
        #expect(!SessionWorkflowPolicy.canRecover(observed: .absent, current: .unknown))
    }

    @Test func onlyVerifiedQuietManagedSessionsCanBulkClose() {
        let verified = SessionWorkflow(owner: "workit", jobID: "job", revision: 1, state: .verified)
        #expect(SessionWorkflowPolicy.shouldCloseVerified(workflow: verified, status: .completed))
        #expect(!SessionWorkflowPolicy.shouldCloseVerified(workflow: verified, status: .executing))
        #expect(!SessionWorkflowPolicy.shouldCloseVerified(workflow: nil, status: .completed))
        let waiting = SessionWorkflow(owner: "workit", jobID: "job", revision: 1, state: .waiting)
        #expect(!SessionWorkflowPolicy.shouldCloseVerified(workflow: waiting, status: .completed))
    }

    @Test func controlRoutesAndPayloadsRemainVersioned() throws {
        #expect(ControlRoute.resolve(method: "POST", path: "/workflow-set") == .workflowSet)
        #expect(ControlRoute.resolve(method: "POST", path: "/workflow-wake") == .workflowWake)
        #expect(ControlRoute.resolve(method: "POST", path: "/workflow-resolve") == .workflowResolve)
        #expect(ControlRoute.resolve(method: "POST", path: "/workflow-close-verified") == .workflowCloseVerified)
        #expect(ControlRoute.resolve(method: "GET", path: "/workflow-wake") == nil)
        let payload = try JSONDecoder().decode(WorkflowControlPayload.self, from: Data(
            #"{"apiVersion":"v1","id":"TASK-123","owner":"workit","jobID":"job-a","revision":"3","state":"waiting"}"#.utf8))
        #expect(try payload.workflow().revision == 3)
        let invalid = try JSONDecoder().decode(WorkflowControlPayload.self, from: Data(
            #"{"id":"TASK-123","owner":"workit","jobID":"job-a","revision":-1,"state":"waiting"}"#.utf8))
        #expect(throws: (any Error).self) { try invalid.workflow() }
    }
}
