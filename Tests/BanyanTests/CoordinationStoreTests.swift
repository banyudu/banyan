import AppKit
import Combine
import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan



@MainActor
@Suite struct CoordinationStoreTests {
    @Test(arguments: ["协调者", String(repeating: "long-session-", count: 40)])
    func createdSessionIDsSupportCoordination(proposedID: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let parent = store.spawn(id: proposedID, cwd: fixture.root.path, command: "codex", select: false)
        #expect(parent.id == proposedID.trimmingCharacters(in: CharacterSet(charactersIn: "-_")))
        let child = try #require(store.sessions.first { $0.id == "managed" })
        try store.reparent(id: child.id, parentSessionID: parent.id)
        _ = try await store.controlCoordination(payload("bind", id: parent.id))
        child.onUserSubmittedInput?(nil)
        #expect(try store.coordinationJournal.interventions(id: child.id).count == 1)
        #expect(child.workflowRecoveryError == nil)
        #expect(child.coordinationRecoveryError == nil)
        #expect(parent.workflowRecoveryError == nil)
    }

    @Test(arguments: ["协调者", "parent: [review]!?/segment", String(repeating: "long-session-", count: 40)])
    func reparentedIDsSupportBindingsInterventionsAndWorkflowRecovery(parentID: String) async throws {
        let childID = "child-" + parentID
        let fixture = try WorkflowStoreFixture(sessionIDs: ["legacy", parentID, childID])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let parent = try #require(store.sessions.first { $0.id == parentID })
        let child = try #require(store.sessions.first { $0.id == childID })
        #expect(parent.workflowRecoveryError == nil)
        #expect(child.workflowRecoveryError == nil)
        try store.reparent(id: childID, parentSessionID: parentID)
        _ = try await store.controlCoordination(payload("bind", id: parentID))
        try store.setWorkflow(id: childID, workflow: .init(owner: "workit", jobID: "child-job", revision: 1, state: .verified))
        child.onUserSubmittedInput?("Keep the existing behavior")
        let inputs = try store.coordinationJournal.interventions(id: childID)
        #expect(inputs.map(\.text) == ["Keep the existing behavior"])
        #expect(child.workflowRecoveryError == nil)
        #expect(child.coordinationRecoveryError == nil)
        let result = try await store.controlCoordination(payload("observe", id: childID, extra: ["parent": parentID]))
        let observed = try #require(result["session"] as? [String: Any])
        #expect((observed["coordinationInterventions"] as? [[String: String]])?.first?["text"] == "Keep the existing behavior")
        store.flushPendingSessionSaves()
        let restored = fixture.makeStore()
        defer { restored.flushPendingSessionSaves() }
        restored.loadPersistedSessionsIfNeeded()
        let restoredChild = try #require(restored.sessions.first { $0.id == childID })
        #expect(restoredChild.parentSessionID == parentID)
        #expect(restoredChild.workflow == child.workflow)
        #expect(restoredChild.workflowRecoveryError == nil)
        #expect(try restored.coordinationJournal.interventions(id: childID) == inputs)
        try restored.close(id: childID)
        #expect(restoredChild.status == .closed)
    }

    @Test(arguments: ["binding", "intervention"])
    func coordinationFailuresHaveTheirOwnDiagnosticsAndFenceAutomatedRetirement(kind: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture)
        defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        let file = store.coordinationJournal.directory.appendingPathComponent(
            kind == "binding" ? "bindings/legacy.json" : "inputs/managed.json")
        if kind == "intervention" {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let before = try? Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        child.onUserSubmittedInput?("Do not retire yet")
        let error = try #require(child.coordinationRecoveryError)
        #expect(error.contains("'managed'"))
        #expect(error.contains("parent 'legacy'"))
        #expect(child.workflowRecoveryError == nil)
        #expect(!store.workNode(for: child).recoveryError)
        let summary = ControlServer(store: store, host: store.host).summary(child)
        #expect(summary["coordinationRecoveryError"] as? String == error)
        #expect(summary["workflowRecoveryError"] == nil)
        if let before { try before.write(to: file) }
        else { try FileManager.default.removeItem(at: file) }
        // Repairing storage and recording a later input cannot acknowledge an
        // earlier lost input. The hold remains scoped to this parent relation.
        child.onUserSubmittedInput?("Later input")
        #expect(child.coordinationRecoveryError == error)
        #expect(!store.verifiedWorkflowSessionIDs.contains(child.id))
        let observed = try await store.controlCoordination(payload("observe", id: child.id, extra: ["parent": "legacy"]))
        #expect((observed["session"] as? [String: Any])?["coordinationRecoveryError"] as? String == error)
        let intervention = try #require(try store.coordinationJournal.interventions(id: child.id).last)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: child.id, extra: ["parent": "legacy", "jobID": "child-job", "revision": 2,
                "interventionID": intervention.id]))
        }
        // Explicit close still checks the real workflow, independently of the
        // coordination hold; verified work can be closed by the operator.
        try store.close(id: child.id)
        #expect(child.status == .closed)
    }

    @Test func explicitCoordinationRecoveryRequiresCurrentInspectionAndRecordsAcknowledgment() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        let binding = store.coordinationJournal.bindings.directory.appendingPathComponent("legacy.json")
        let original = try Data(contentsOf: binding)
        let scope: [String: Any] = ["parent": "legacy"]
        try Data("{".utf8).write(to: binding)
        child.onUserSubmittedInput?("Potentially lost input")
        let unavailable = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        #expect(unavailable["recoverable"] as? Bool == false)
        #expect((unavailable["nextAction"] as? String)?.contains("coordination journal") == true)
        try original.write(to: binding)
        child.onUserSubmittedInput?("Later input")
        let inspection = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        let token = try #require(inspection["inspectionID"] as? String)
        #expect(inspection["recoverable"] as? Bool == true)
        let recovery = scope.merging(["inspectionID": token, "detail": "Inspected the conversation and accounted for the missing input."]) { _, new in new }
        child.onUserSubmittedInput?("Changed after inspection")
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("recover", id: child.id, extra: recovery)) }
        #expect(child.coordinationRecoveryError != nil)
        let next = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        let nextToken = try #require(next["inspectionID"] as? String)
        try Data("{".utf8).write(to: binding)
        child.onUserSubmittedInput?("A newer failure")
        try original.write(to: binding)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("recover", id: child.id, extra: scope.merging(["inspectionID": nextToken, "detail": "Inspected"]) { _, new in new }))
        }
        let final = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        let finalToken = try #require(final["inspectionID"] as? String)
        let workflowFile = store.workflowJournal.directory.appendingPathComponent("managed.json")
        let workflowData = try Data(contentsOf: workflowFile)
        try Data("{".utf8).write(to: workflowFile)
        let corrupt = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        #expect(corrupt["recoverable"] as? Bool == false)
        #expect((corrupt["nextAction"] as? String)?.contains("workflow journal") == true)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("recover", id: child.id, extra: scope.merging(["inspectionID": finalToken, "detail": "Inspected"]) { _, new in new }))
        }
        try workflowData.write(to: workflowFile)
        let current = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        let currentToken = try #require(current["inspectionID"] as? String)
        let accepted = scope.merging(["inspectionID": currentToken, "detail": "Inspected the conversation and accounted for missing input."]) { _, new in new }
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("recover", id: child.id, group: "other", extra: accepted)) }
        _ = try await store.controlCoordination(payload("recover", id: child.id, extra: accepted))
        #expect(child.parentSessionID == "legacy")
        #expect(child.coordinationRecoveryError == nil)
        #expect(child.workflow?.state == .verified)
        #expect(fixture.backend.sent.isEmpty)
        let observed = try await store.controlCoordination(payload("observe", id: child.id, extra: scope))
        let entries = try #require((observed["session"] as? [String: Any])?["coordinationInterventions"] as? [[String: String]])
        #expect(entries.last?["text"]?.contains("accounted for missing input") == true)
        let lastID = try #require(entries.last?["id"])
        _ = try await store.controlCoordination(payload("retire", id: child.id, extra: ["parent": "legacy", "jobID": "child-job", "revision": 2, "interventionID": lastID]))
        #expect(child.status == .closed)
    }

    @Test func coordinationRecoveryRetainsFailureWhenAcknowledgmentCannotBeWritten() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        let binding = store.coordinationJournal.bindings.directory.appendingPathComponent("legacy.json")
        let original = try Data(contentsOf: binding)
        try Data("{".utf8).write(to: binding)
        child.onUserSubmittedInput?("Potentially lost input")
        try original.write(to: binding)
        child.onUserSubmittedInput?("Later input")
        let inputs = store.coordinationJournal.directory.appendingPathComponent("inputs")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inputs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inputs.path) }
        let scope: [String: Any] = ["parent": "legacy"]
        let inspection = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        #expect((inspection["nextAction"] as? String)?.contains("successful coordination journal write") == true)
        let token = try #require(inspection["inspectionID"] as? String)
        do {
            _ = try await store.controlCoordination(payload("recover", id: child.id,
                extra: ["parent": "legacy", "inspectionID": token, "detail": "Inspected the original conversation"]))
            Issue.record("Expected acknowledgment write to fail")
        } catch {
            #expect(error.localizedDescription.contains("coordination acknowledgment could not be written"))
            #expect(error.localizedDescription.contains("coordination error remains"))
        }
        #expect(child.coordinationRecoveryError != nil)
        #expect(try store.coordinationJournal.interventions(id: child.id).map(\.text) == ["Later input"])
        #expect(fixture.backend.sent.isEmpty)
    }

    @Test func coordinationRecoveryPreservesWorkflowHoldAndUnresolvedReceipt() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        let held = SessionWorkflow(owner: "workit", jobID: "child-job", revision: 2, state: .needsYou,
                                   wake: .init(id: "wake", status: .uncertain))
        try store.workflowJournal.save(held, id: child.id)
        child.workflow = held
        let file = store.coordinationJournal.bindings.directory.appendingPathComponent("legacy.json")
        let original = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        child.onUserSubmittedInput?("Input")
        try original.write(to: file)
        child.workflowRecoveryError = "Actual workflow journal failure"
        let scope: [String: Any] = ["parent": "legacy"]
        let blocked = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        #expect(blocked["recoverable"] as? Bool == false)
        #expect((blocked["nextAction"] as? String)?.contains("workflow journal recovery error") == true)
        #expect(child.workflowRecoveryError != nil)
        child.workflowRecoveryError = nil
        let inspection = try await store.controlCoordination(payload("inspect-recovery", id: child.id, extra: scope))
        let token = try #require(inspection["inspectionID"] as? String)
        _ = try await store.controlCoordination(payload("recover", id: child.id, extra: ["parent": "legacy", "inspectionID": token, "detail": "Inspected original input"]))
        #expect(child.workflow == held)
        #expect(try store.workflowJournal.load(id: child.id) == held)
        #expect(throws: (any Error).self) { try store.close(id: child.id) }
        #expect(!store.verifiedWorkflowSessionIDs.contains(child.id))
        let verified = SessionWorkflow(owner: "workit", jobID: "child-job", revision: 3, state: .verified,
                                       wake: .init(id: "wake", status: .uncertain))
        try store.workflowJournal.save(verified, id: child.id)
        child.workflow = verified
        #expect(!store.verifiedWorkflowSessionIDs.contains(child.id))
        let latest = try #require(try store.coordinationJournal.interventions(id: child.id).last)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: child.id, extra: ["parent": "legacy", "jobID": "child-job", "revision": 3, "interventionID": latest.id]))
        }
    }

    @Test func changingParentClearsOnlyTheCoordinationHoldAndKeepsWorkflowCloseGuards() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture)
        defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        child.coordinationRecoveryError = "Input under parent 'legacy' could not be recorded"
        child.workflowRecoveryError = "Actual workflow journal failure"
        try store.reparent(id: child.id, parentSessionID: "legacy")
        #expect(child.coordinationRecoveryError != nil) // No relationship change.
        try store.reparent(id: child.id, parentSessionID: "busy")
        #expect(child.coordinationRecoveryError == nil)
        #expect(child.workflowRecoveryError == "Actual workflow journal failure")
        #expect(throws: (any Error).self) { try store.close(id: child.id) }
        child.workflowRecoveryError = nil
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 1, state: .working))
        child.coordinationRecoveryError = "Another coordination failure"
        try store.reparent(id: child.id, parentSessionID: nil)
        #expect(child.coordinationRecoveryError == nil)
        #expect(throws: (any Error).self) { try store.close(id: child.id) }
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        let file = store.workflowJournal.directory.appendingPathComponent(child.id + ".json")
        try Data("{".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.close(id: child.id) }
    }

    @Test func coordinationFailureAllowsExplicitCloseWhenNoIssueWorkflowExists() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture)
        defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        let file = store.coordinationJournal.bindings.directory.appendingPathComponent("legacy.json")
        try Data("{".utf8).write(to: file)
        child.onUserSubmittedInput?("Inspect this child")
        #expect(child.coordinationRecoveryError != nil)
        #expect(child.workflow == nil)
        #expect(child.workflowRecoveryError == nil)
        child.onProcessExit?(0)
        #expect(child.status != .closed)
        try store.close(id: child.id)
        #expect(child.status == .closed)
    }

    func payload(_ action: String, id: String = "legacy", group: String = "group-a",
                         extra: [String: Any] = [:]) throws -> CoordinationControlPayload {
        var values: [String: Any] = ["action": action, "id": id, "groupID": group]
        values.merge(extra) { _, new in new }
        return try JSONDecoder().decode(CoordinationControlPayload.self, from: JSONSerialization.data(withJSONObject: values))
    }
    private func setup(_ fixture: WorkflowStoreFixture) async throws -> SessionStore {
        let store = fixture.makeStore()
        store.loadPersistedSessionsIfNeeded()
        store.selection.selectedSessionID = "legacy"
        store.sessions.first { $0.id == "managed" }?.parentSessionID = "legacy"
        store.sessions.first { $0.id == "busy" }?.parentSessionID = "legacy"
        _ = try await store.controlCoordination(payload("bind"))
        return store
    }
    @Test func bindingDoesNotOverwriteIssueWorkflowAndCannotStealAnotherGroup() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "legacy", workflow: .init(owner: "workit", jobID: "parent-job", revision: 8, state: .paused))
        _ = try await store.controlCoordination(payload("bind"))
        #expect(store.sessions.first { $0.id == "legacy" }?.workflow?.jobID == "parent-job")
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("bind", group: "other")) }
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Continue"]))
        }
        #expect(fixture.backend.launched.isEmpty)
    }
    @Test func deliveredMessageCannotChangeIdentityOrContentAtSameRevision() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.coordinationJournal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-a", revision: 1,
            state: .working, detail: "Update", wake: .init(id: "a", status: .delivered)), id: "legacy")
        _ = try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        for extra: [String: Any] in [["revision": 1, "wakeID": "b", "text": "Update"], ["revision": 1, "wakeID": "a", "text": "Changed"], ["revision": 0, "wakeID": "old", "text": "Update"]] {
            await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("deliver", extra: extra)) }
        }
        _ = try await store.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        #expect(fixture.backend.launched.isEmpty)
        #expect(fixture.backend.sent.isEmpty)
    }
    @Test func pendingCoordinatorReceiptSurvivesRestartAndNeverReplays() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.coordinationJournal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-a", revision: 1,
            state: .working, detail: "Update", wake: .init(id: "a", status: .pending)), id: "legacy")
        let restored = fixture.makeStore(); restored.loadPersistedSessionsIfNeeded()
        defer { restored.flushPendingSessionSaves() }
        await #expect(throws: (any Error).self) {
            try await restored.controlCoordination(payload("deliver", extra: ["revision": 1, "wakeID": "a", "text": "Update"]))
        }
        #expect(fixture.backend.launched.isEmpty)
        #expect(try restored.coordinationJournal.bindings.load(id: "legacy")?.wake?.status == .pending)
    }
    @Test func retirementIsScopedQuietRevisionGuardedAndRetainsHistory() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 4, state: .verified))
        try store.setWorkflow(id: "busy", workflow: .init(owner: "workit", jobID: "busy-job", revision: 4, state: .verified))
        let base: [String: Any] = ["parent": "legacy", "jobID": "child-job", "revision": 4]
        for extra: [String: Any] in [["parent": "other", "jobID": "child-job", "revision": 4], ["parent": "legacy", "jobID": "wrong", "revision": 4], ["parent": "legacy", "jobID": "child-job", "revision": 3]] {
            await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire", id: "managed", extra: extra)) }
        }
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: "busy", extra: ["parent": "legacy", "jobID": "busy-job", "revision": 4]))
        }
        store.selection.selectedSessionID = "managed"
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire", id: "managed", extra: base)) }
        store.selection.selectedSessionID = "legacy"
        _ = try await store.controlCoordination(payload("retire", id: "managed", extra: base))
        #expect(store.sessions.first { $0.id == "managed" }?.status == .closed)
        #expect(store.sessions.first { $0.id == "busy" }?.status == .executing)
        #expect(store.sessions.first { $0.id == "legacy" }?.status != .closed)
        _ = try await store.controlCoordination(payload("retire", id: "managed", extra: base))
    }
    @Test func directInputPersistsAndInvalidatesEarlierRetirement() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        let child = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        child.onUserSubmittedInput?("Keep the existing UI")
        let values = try store.coordinationJournal.interventions(id: child.id)
        #expect(values.count == 1)
        #expect(values.first?.text == "Keep the existing UI")
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: child.id, extra: ["parent": "legacy", "jobID": "child-job", "revision": 2]))
        }
        let restored = fixture.makeStore()
        #expect(try restored.coordinationJournal.interventions(id: child.id) == values)
    }
    @Test func replacedPaneDuringRetirementIsNeverKilled() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 2, state: .verified))
        fixture.backend.replacementAfterFirstInspection = TmuxPaneSnapshot(paneID: "%replacement", rootPID: 333,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire", id: "managed", extra: ["parent": "legacy", "jobID": "child-job", "revision": 2]))
        }
        #expect(fixture.backend.killed.isEmpty)
    }
}

extension CoordinationStoreTests {
    @Test func helperRetirementRequiresOriginalWorkerRunAndVerifiedRevision() async throws {
        let fixture = try WorkflowStoreFixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try await setup(fixture); defer { store.flushPendingSessionSaves() }
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "child-job", revision: 4, state: .verified))
        let helper = try #require(store.sessions.first { $0.id == "busy" }); helper.status = .completed
        let binding: [String: Any] = ["parent": "legacy", "worker": "managed", "runID": "review", "jobID": "child-job", "revision": 4]
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding)) }
        _ = try await store.controlCoordination(payload("helper", id: helper.id, extra: binding))
        await #expect(throws: (any Error).self) {
            try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding.merging(["runID": "other"]) { _, new in new }))
        }
        helper.onUserSubmittedInput?("Inspect this verifier before closing")
        await #expect(throws: (any Error).self) { try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding)) }
        let intervention = try #require(store.coordinationJournal.interventions(id: helper.id).last)
        _ = try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding.merging(["interventionID": intervention.id]) { _, new in new }))
        #expect(helper.status == .closed)
        #expect(store.sessions.first { $0.id == "managed" }?.status != .closed)
        _ = try await store.controlCoordination(payload("retire-helper", id: helper.id, extra: binding))
    }
}
