import AppKit
import Combine
import BanyanCore
import Foundation
import Network
import Testing
@testable import Banyan


@MainActor
@Suite struct SessionWorkflowStoreTests {
    @Test(arguments: ["legacy", "profile", "empty", "narrow", "malformed", "extra", "draft", "multiline",
        "approval", "settings", "model", "shell", "busy", "parked", "frozen", "copy-mode"], ["wake", "retire"])
    func compiledFooterObservationHasNoDeliveryEffects(scenario: String, caller: String) async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let footer = "Model-v2 high · ~/dev/my-project · Context 48% used · weekly 99% left"
        var screen = "Work complete\n› Ask Codex to do anything\n\n\(footer) · Research Team [research_2]\n? for shortcuts"
        switch scenario {
        case "legacy": screen = screen.replacingOccurrences(of: " · Research Team [research_2]", with: "")
        case "empty": screen = screen.replacingOccurrences(of: "› Ask Codex to do anything", with: "›")
        case "narrow": screen = "Work complete\n› Ask Codex to do anything\n\nModel-v2 high · ~/dev/my-project/.worktrees/task-123-with-a-long-session-name-sess…\n? for shortcuts"
        case "malformed": screen = screen.replacingOccurrences(of: "[research_2]", with: "[[research_2]]")
        case "extra": screen += "\nUnexpected footer field"
        case "draft": screen = screen.replacingOccurrences(of: "Ask Codex to do anything", with: "Unsent draft")
        case "multiline": screen = screen.replacingOccurrences(of: "Ask Codex to do anything", with: "Ask Codex to do anything\nSecond draft line")
        case "approval": screen += "\nWould you like to run this command?\n› 1. Yes, proceed\n2. No"
        case "settings": screen += "\nSettings · Permissions\nPress esc to close"
        case "model": screen += "\nSelect model\n› 1. Model-v2\nPress enter to confirm"
        default: break
        }
        // Synthetic PIDs and an injected table: no provider or real process runs.
        let pane = TmuxPaneSnapshot(paneID: "%fixture", rootPID: 2_000_000_000,
            currentCommand: "zsh", currentPath: fixture.root.path, isDead: false, isInMode: scenario == "copy-mode")
        fixture.backend.readablePane = pane
        fixture.backend.visibleText = screen
        var rows: [ProcessInfoRow] = scenario == "shell" ? [] : [
            .init(pid: 2_000_000_001, parentPID: pane.rootPID, state: "S", elapsed: 10, commandName: "codex", arguments: "codex")
        ]
        if scenario == "busy" {
            rows.append(.init(pid: 2_000_000_002, parentPID: 2_000_000_001, state: "S", elapsed: 1,
                commandName: "curl", arguments: "curl https://example.com"))
        }
        let native = WorkflowObserverService()
        let store = fixture.makeStore(processes: WorkflowTestProcesses(rows: rows), codexService: native)
        defer { store.flushPendingSessionSaves(); store.workOverviewRefreshTask?.cancel() }
        store.loadPersistedSessionsIfNeeded()
        store.selectedSessionID = "legacy"
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.parentSessionID = "legacy"
        terminal.isSuspended = scenario == "parked"
        terminal.isFrozen = scenario == "frozen"
        let positive = ["legacy", "profile", "empty", "narrow"].contains(scenario)
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 4,
            state: positive || caller == "retire" ? .verified : .waiting,
            wake: .init(id: "earlier", status: .delivered))
        try store.setWorkflow(id: terminal.id, workflow: workflow)
        try store.coordinationJournal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-a",
            revision: 1, state: .working), id: "legacy")
        let journalURL = store.workflowJournal.directory.appendingPathComponent("managed.json")
        let bindingURL = store.coordinationJournal.bindings.directory.appendingPathComponent("legacy.json")
        let journalBefore = try Data(contentsOf: journalURL)
        let bindingBefore = try Data(contentsOf: bindingURL)
        let commandBefore = terminal.command

        let reading = try await store.readPaneOutput(id: terminal.id, lines: nil)
        #expect(reading.paneID == pane.paneID)
        #expect(reading.visibleText == screen)
        let candidate = SessionWorkflowPolicy.canWake(status: reading.status, isSuspended: terminal.isSuspended,
            isFrozen: terminal.isFrozen, isDeepSuspended: terminal.isDeepSuspended,
            hasObservation: reading.observation != nil, isAgent: reading.observation?.provider != nil,
            hasHumanPrompt: reading.prompt != nil, hasEmptyInput: SessionWorkflowPolicy.hasEmptyInput(reading.visibleText))
            && !pane.isInMode
        #expect(candidate == positive)
        if positive {
            #expect(reading.status == .needInput)
            #expect(reading.observation?.provider == .codex)
            #expect(reading.prompt == nil)
            // Readability cannot override the verified workflow's delivery hold.
            do {
                try await store.wakeWorkflow(id: terminal.id, jobID: "job-a", revision: 4, wakeID: "new", text: "Continue")
                Issue.record("Expected verified workflow refusal")
            } catch { #expect(error.localizedDescription == "workflow is verified") }
        } else if caller == "wake" {
            do {
                try await store.wakeWorkflow(id: terminal.id, jobID: "job-a", revision: 4, wakeID: "new", text: "Continue")
                Issue.record("Expected guarded wake refusal")
            } catch {
                #expect(["unsupported or uncertain agent session", "agent is busy, unobserved, or awaiting human input",
                    "session is closed, parked, frozen or unavailable"].contains(error.localizedDescription))
            }
        } else {
            if scenario == "shell" { #expect(reading.observation?.provider == nil) }
            if ["parked", "frozen"].contains(scenario) { #expect(reading.observation == nil) }
            // Exercise the real retirement caller without ever closing a pane.
            let payload = try JSONDecoder().decode(CoordinationControlPayload.self, from: Data(
                #"{"action":"retire","id":"managed","groupID":"group-a","parent":"legacy","jobID":"job-a","revision":4}"#.utf8))
            do {
                _ = try await store.controlCoordination(payload)
                Issue.record("Expected guarded retirement refusal")
            } catch {
                #expect(["child is busy or awaiting user input", "selected or suspended children are retained"].contains(error.localizedDescription))
            }
        }
        #expect(terminal.status != .closed)
        #expect(terminal.command == commandBefore)
        #expect(terminal.workflow == workflow)
        #expect(try Data(contentsOf: journalURL) == journalBefore)
        #expect(try Data(contentsOf: bindingURL) == bindingBefore)
        #expect(try store.coordinationJournal.interventions(id: terminal.id).isEmpty)
        #expect(fixture.backend.sent.isEmpty) // literal input and keys
        #expect(fixture.backend.launched.isEmpty) // terminal resume and new conversation
        #expect(fixture.backend.killed.isEmpty)
        #expect(native.requests.isEmpty) // includes thread/resume and turn/start
    }

    @Test func closedWorkflowUpdatesPersistWithoutRedrawingTheWindowOrRefreshingWorkit() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        session.status = .closed
        session.isTitlePinned = true
        store.workOverviewRefreshTask?.cancel()
        store.workOverviewRefreshTask = nil
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }

        for revision in 1...5 {
            try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a",
                revision: revision, state: .paused, detail: "Waiting for the operator"))
        }
        #expect(publications == 0)
        #expect(store.workOverviewRefreshTask == nil)
        #expect(session.workflow?.revision == 5)
        #expect(try store.workflowJournal.load(id: session.id) == session.workflow)
        #expect(store.sessionWorkSummaries[session.id] == nil)
        #expect(throws: (any Error).self) {
            try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a",
                revision: 4, state: .working))
        }

        // History titles and a reopened conversation still update the sidebar.
        session.title = "Renamed conversation"
        #expect(publications > 0)
        publications = 0
        session.status = .completed
        #expect(publications > 0)
        #expect(store.sessionWorkSummaries[session.id]?.own.label == "Paused")
        publications = 0
        try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a",
            revision: 6, state: .working))
        #expect(publications > 0)
        #expect(store.workOverviewRefreshTask != nil)
        #expect(store.sessionWorkSummaries[session.id]?.own.label == "Agent finished · workflow unfinished")
        session.status = .executing
        #expect(store.sessionWorkSummaries[session.id]?.own.label == "Working")
        session.status = .needInput
        #expect(store.sessionWorkSummaries[session.id]?.own.label == "Waiting for input · workflow unfinished")
        store.workOverviewRefreshTask?.cancel()
    }

    @Test func duplicateWorkflowProjectionDoesNotRepublishTheSession() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 1, state: .paused)
        try store.setWorkflow(id: session.id, workflow: workflow)
        var publications = 0
        let subscription = session.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel(); store.workOverviewRefreshTask?.cancel() }
        try store.setWorkflow(id: session.id, workflow: workflow)
        #expect(publications == 0)
        #expect(try store.workflowJournal.load(id: session.id) == workflow)
    }

    @Test func workflowChangesUpdateOnlyTheirRowAndAncestors() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves(); store.workOverviewRefreshTask?.cancel() }
        store.loadPersistedSessionsIfNeeded()
        // Keep an unrelated asynchronous titlebar lookup out of the publication
        // count, including when the test runner is under heavy CPU pressure.
        store.selectedSessionID = nil
        let child = try #require(store.sessions.first { $0.id == "managed" })
        child.parentSessionID = "legacy"
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "job-a",
            revision: 0, state: .needsYou, detail: "Initial detail"))
        let childState = store.workState(for: child.id)
        let parentState = store.workState(for: "legacy")
        let unrelated = store.workState(for: "busy")
        await store.workSummaryUpdateTask?.value
        var windowUpdates = 0, childUpdates = 0, parentUpdates = 0, unrelatedUpdates = 0
        let subscriptions = [
            store.objectWillChange.sink { windowUpdates += 1 },
            childState.objectWillChange.sink { childUpdates += 1 },
            parentState.objectWillChange.sink { parentUpdates += 1 },
            unrelated.objectWillChange.sink { unrelatedUpdates += 1 }
        ]
        defer { for subscription in subscriptions { subscription.cancel() } }
        for revision in 1...5 {
            try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "job-a",
                revision: revision, state: .needsYou))
        }
        try await waitForPuckState { childState.summary?.own.detail == "" }
        #expect(childUpdates == 1 && parentUpdates == 1)
        #expect(unrelatedUpdates == 0 && windowUpdates == 0)
        #expect(parentState.summary?.groupLabel == "1 blocked")
        #expect(try store.workflowJournal.load(id: child.id)?.revision == 5)
        try store.setWorkflow(id: child.id, workflow: .init(owner: "workit", jobID: "job-a",
            revision: 6, state: .paused))
        #expect(windowUpdates > 0) // Close/menu permissions change with workflow state.
    }

    @Test func restoredCompletedAgentCannotReplayItsInitialPromptWithoutAResumeTarget() throws {
        for sourceID in [nil, "", "unresumable"] as [String?] {
            let fixture = try WorkflowStoreFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let store = fixture.makeStore(history: WorkflowTestHistory(supportsResume: false))
            defer { store.flushPendingSessionSaves() }
            store.loadPersistedSessionsIfNeeded()
            let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
            terminal.agentSessionID = sourceID
            try store.setWorkflow(id: terminal.id, workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .needsYou))
            #expect(terminal.needsRecovery)
            #expect(terminal.needsManualAttach)
            terminal.startBackgroundBackendIfNeeded()
            terminal.start()
            terminal.recoverFromMissingBackingSession()
            terminal.recoverFromMissingBackingSessionInBackground()
            #expect(throws: (any Error).self) { try store.recover(id: terminal.id) }
            #expect(terminal.status == .completed)
            #expect(terminal.needsRecovery)
            #expect(terminal.command.contains("Original implementation prompt"))
            #expect(!terminal.isProcessStarted)
            #expect(fixture.backend.launched.isEmpty)
            #expect(store.historyResumeError(id: terminal.id)?.contains("original command was not restarted") == true)
        }
    }

    @Test func completedAgentRecoveryResumesTheRecordedConversationWithoutTheInitialPrompt() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = "11111111-2222-3333-4444-555555555555"
        try store.recover(id: terminal.id, select: false)
        try await waitForPuckState { terminal.isProcessStarted }
        #expect(terminal.command.contains("resume"))
        #expect(terminal.command.contains(terminal.agentSessionID!))
        #expect(!terminal.command.contains("Original implementation prompt"))
        #expect(!terminal.needsRecovery)
        #expect(fixture.backend.launched.allSatisfy { $0.contains("resume") && !$0.contains("Original implementation prompt") })
    }

    @Test func restoredAgentWhoseBackendDisappearedAfterStartupDoesNotReplayItsPrompt() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        // Startup saw a live pane, which vanished before the first selection.
        terminal.needsRecovery = false
        terminal.status = .needInput
        terminal.startBackgroundBackendIfNeeded()
        try await waitForPuckState { terminal.needsRecovery }
        #expect(terminal.needsManualAttach)
        #expect(!terminal.isProcessStarted)
        #expect(fixture.backend.launched.isEmpty)
        #expect(terminal.command.contains("Original implementation prompt"))
    }

    @Test func restoredAgentAttachmentNeverUsesTheBackingCreationPath() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.needsRecovery = false
        terminal.status = .needInput
        fixture.backend.observedPane = TmuxPaneSnapshot(paneID: "%existing", rootPID: 42,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        terminal.startBackgroundBackendIfNeeded()
        try await waitForPuckState { terminal.isProcessStarted }
        #expect(!terminal.needsRecovery)
        #expect(fixture.backend.launched.isEmpty)
    }

    @Test func restoreSeparatesProcessCompletionFromIssueCompletionAndProtectsClose() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .waiting))
        let restored = fixture.makeStore()
        restored.loadPersistedSessionsIfNeeded()
        let managed = try #require(restored.sessions.first { $0.id == "managed" })
        #expect(managed.status == .completed)
        #expect(managed.workflow?.state == .waiting)
        restored.applySupervisorResults([SessionStatusObservation(id: "managed", status: .closed,
            tone: .neutral, provider: .codex, currentPath: nil)])
        #expect(managed.status == .completed)
        #expect(managed.needsRecovery)
        #expect(throws: (any Error).self) { try restored.close(id: "managed") }
        #expect(managed.status == .completed)
        #expect(restored.sessions.first { $0.id == "legacy" }?.workflow == nil)
    }

    @Test func bulkCloseSelectsOnlyVerifiedQuietSessions() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .verified))
        try store.setWorkflow(id: "busy", workflow: .init(owner: "workit", jobID: "job-b", revision: 0, state: .verified))
        #expect(store.verifiedWorkflowSessionIDs == ["managed"])
        #expect(try store.closeVerifiedWorkflows() == ["managed"])
        #expect(store.sessions.first { $0.id == "legacy" }?.status == .completed)
        #expect(store.sessions.first { $0.id == "busy" }?.status == .executing)
    }

    @Test func receiptsSurviveStoreRestartAndNeedExplicitReconciliation() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let pending = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 3, state: .waiting,
            wake: .init(id: "wake-a", status: .pending))
        try store.setWorkflow(id: "managed", workflow: pending)
        let restored = fixture.makeStore()
        restored.loadPersistedSessionsIfNeeded()
        await #expect(throws: (any Error).self) {
            try await restored.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a", text: "Continue")
        }
        #expect(fixture.backend.sent.isEmpty)
        try restored.resolveWorkflowWake(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a",
            outcome: "delivered", detail: "Original conversation inspected")
        try await restored.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a", text: "Continue")
        #expect(fixture.backend.sent.isEmpty)
    }

    @Test func refusedWakeStaysVisibleUntilAWakeSucceedsOrTheAgentWorks() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: SessionWorkflow(owner: "workit", jobID: "job-a", revision: 3,
            state: .waiting, wake: .init(id: "wake-a", status: .delivered)))
        let session = try #require(store.sessions.first { $0.id == "managed" })
        func refuse() async {
            session.isSuspended = true
            await #expect(throws: WorkflowError.self) {
                try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-b", text: "Continue")
            }
            session.isSuspended = false
        }
        await refuse()
        #expect(session.workflowWakeRefusal == "session is closed, parked, frozen or unavailable")
        #expect(store.workNode(for: session).wakeRefusal == session.workflowWakeRefusal)
        // The already-delivered receipt is a successful no-op wake.
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 3, wakeID: "wake-a", text: "Continue")
        #expect(session.workflowWakeRefusal == nil)
        await refuse()
        session.status = .executing
        #expect(session.workflowWakeRefusal == nil)
        #expect(fixture.backend.sent.isEmpty)
    }

    @Test func unavailableConversationIdentityNeverReplaysTheOriginalCommand() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        await #expect(throws: (any Error).self) {
            try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue")
        }
        #expect(fixture.backend.sent.isEmpty)
        #expect(fixture.backend.launched.isEmpty)
    }

    @Test func missingPaneResumesTheRecordedConversationAndDeduplicates() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceID = "11111111-2222-3333-4444-555555555555"
        let history = WorkflowTestHistory(candidates: [.init(provider: .codex, sourceID: sourceID,
            cwd: fixture.root.path, createdAt: Date(), updatedAt: Date())])
        let store = fixture.makeStore(history: history)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = sourceID
        terminal.command = "codex --model example 'Original implementation prompt'"
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue verification")
        #expect(terminal.command.contains("resume"))
        #expect(terminal.command.contains(sourceID))
        #expect(terminal.command.contains("Continue verification"))
        #expect(terminal.command.contains("--model") && terminal.command.contains("example"))
        #expect(!terminal.command.contains("Original implementation prompt"))
        #expect(terminal.workflow?.wake?.status == .delivered)
        let command = terminal.command
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Duplicate")
        #expect(terminal.command == command)
    }

    @Test func missingPaneAppServerWakePreservesLaunchOptions() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceID = "11111111-2222-3333-4444-555555555555"
        let history = WorkflowTestHistory(candidates: [.init(provider: .codex, sourceID: sourceID,
            cwd: fixture.root.path, createdAt: Date(), updatedAt: Date())])
        let store = fixture.makeStore(history: history)
        defer { store.flushPendingSessionSaves() }
        store.enableCodexAppServerMode = true
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = sourceID
        terminal.command = "'codex' 'remote-control' 'start' && exec 'codex' '--remote' 'unix://' '--model' 'example' 'Original implementation prompt'"
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue verification")

        let prefix = "'codex' 'remote-control' 'start' && exec "
        #expect(terminal.command.hasPrefix(prefix))
        let invocation = String(terminal.command.dropFirst(prefix.count))
        #expect(AgentSessionHistory.literalArguments(invocation) == [
            "codex", "--remote", "unix://", "--model", "example", "resume", "-C", fixture.root.path,
            sourceID, "Continue verification"
        ])
        #expect(!terminal.command.contains("Original implementation prompt"))
    }

    @Test func aReplacementPaneDuringHistoryLookupBlocksRecovery() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceID = "11111111-2222-3333-4444-555555555555"
        let history = WorkflowTestHistory(candidates: [.init(provider: .codex, sourceID: sourceID,
            cwd: fixture.root.path, createdAt: Date(), updatedAt: Date())])
        let store = fixture.makeStore(history: history)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let terminal = try #require(store.sessions.first { $0.id == "managed" } as? TerminalSession)
        terminal.agentSessionID = sourceID
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        fixture.backend.replacementAfterFirstInspection = TmuxPaneSnapshot(paneID: "%new", rootPID: 42,
            currentCommand: "codex", currentPath: fixture.root.path, isDead: false, isInMode: false)
        await #expect(throws: (any Error).self) {
            try await store.wakeWorkflow(id: "managed", jobID: "job-a", revision: 0, wakeID: "wake-a", text: "Continue")
        }
        #expect(terminal.workflow?.wake == nil)
        #expect(terminal.command.contains("Original implementation prompt"))
        #expect(fixture.backend.launched.isEmpty)
    }
}

extension SessionWorkflowStoreTests {
    @Test func linearSidebarUsesOnlyTheFixtureCommand() async throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        store.sidebarMode = .linear
        try await waitForPuckState { FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("linear-invoked").path) }
        try await waitForPuckState { if case .failed = store.linearIssueListLoadState { return true }; return false }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("linear-invoked"), encoding: .utf8) == "fixture")
        let log = fixture.root.appendingPathComponent("Banyan/linear-debug.log")
        #expect(try String(contentsOf: log, encoding: .utf8).contains("command start"))
    }

    @Test func hideKeepsWorkflowAndBackingWorkAndRestoresAfterRestart() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pause = FakeWorkitPauseClient()
        let store = fixture.makeStore(pauseClient: pause)
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        let child = try #require(store.sessions.first { $0.id == "legacy" })
        child.parentSessionID = session.id
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 2, state: .working)
        try store.setWorkflow(id: session.id, workflow: workflow)
        let before = (session.status, session.command, session.isSuspended, session.isFrozen)
        store.sidebarMode = .linear
        try store.hideAndKeepWorking(id: session.id)
        #expect(store.backgroundedSessionIDs.contains(child.id))
        #expect(store.visibleSessions.contains { $0.id == session.id })
        #expect(store.sidebarMode == .linear)
        #expect(store.foldedParentIDs.contains(session.id))
        #expect(store.sessionWorkSummaries[session.id]?.descendants.count == 1)
        child.workflow = .init(owner: "workit", jobID: "child-job", revision: 1, state: .waiting)
        #expect(store.sessionWorkSummaries[session.id]?.groupLabel == "1 waiting")
        #expect(session.workflow == workflow)
        #expect(session.status == before.0 && session.command == before.1 && session.isSuspended == before.2 && session.isFrozen == before.3)
        #expect(pause.requests.isEmpty && fixture.backend.killed.isEmpty && fixture.backend.launched.isEmpty)
        let restored = fixture.makeStore()
        defer { restored.flushPendingSessionSaves() }
        restored.loadPersistedSessionsIfNeeded()
        #expect(restored.backgroundSessionRoots == ["managed"])
        #expect(restored.sidebarMode == .sessions)
        #expect(restored.visibleSessions.contains { $0.id == "managed" })
        #expect(restored.sessions.first { $0.id == "managed" }?.workflow == workflow)
        try store.revealBackgroundConversation(id: child.id)
        #expect(store.backgroundedSessionIDs.isEmpty)
        #expect(try store.backgroundJournal.load().isEmpty)
        #expect(session.workflow == workflow)
    }

    @Test func failedPresentationSaveCannotHideOrPauseWork() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        try store.setWorkflow(id: "managed", workflow: .init(owner: "workit", jobID: "job-a", revision: 0, state: .working))
        try FileManager.default.createDirectory(at: store.backgroundJournal.file, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try store.hideAndKeepWorking(id: "managed") }
        #expect(store.backgroundSessionRoots.isEmpty)
        #expect(store.sessions.first { $0.id == "managed" }?.workflow?.state == .working)
        #expect(fixture.backend.killed.isEmpty)
    }

    @Test func attentionNavigationRevealsBackgroundWorkWithoutChangingWorkflow() throws {
        let fixture = try WorkflowStoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        defer { store.flushPendingSessionSaves() }
        store.loadPersistedSessionsIfNeeded()
        let session = try #require(store.sessions.first { $0.id == "managed" })
        try store.setWorkflow(id: session.id, workflow: .init(owner: "workit", jobID: "job-a", revision: 1, state: .working))
        try store.hideAndKeepWorking(id: session.id)
        let workflow = SessionWorkflow(owner: "workit", jobID: "job-a", revision: 2, state: .needsYou)
        try store.setWorkflow(id: session.id, workflow: workflow)
        session.status = .asking
        store.selection.selectedSessionID = "legacy"
        #expect(store.backgroundSessionRoots.contains(session.id))
        #expect(store.canSelectSessionNeedingAttention)
        store.selectNextSessionNeedingAttention()
        #expect(store.selection.selectedSessionID == session.id)
        #expect(store.backgroundSessionRoots.isEmpty)
        #expect(try store.backgroundJournal.load().isEmpty)
        #expect(session.workflow == workflow)
        #expect(fixture.backend.killed.isEmpty && fixture.backend.launched.isEmpty)
    }
}
