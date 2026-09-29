import Foundation
import Testing
@testable import BanyanCore

@Test func puckStatusPolicyMapsDaemonPositionsOntoSessionStatus() {
    func status(
        _ position: String,
        history: Int = 0,
        approval: Bool = false,
        question: Bool = false
    ) -> SessionStatus {
        PuckSessionStatusPolicy.status(
            position: position,
            historyItems: history,
            hasPendingApproval: approval,
            hasPendingQuestion: question
        )
    }

    #expect(status("running") == .executing)
    #expect(status("parked") == .asking)
    #expect(status("interrupted") == .failed)
    // Idle and hibernated read the same: a finished turn has a result to
    // read, an untouched session has nothing yet.
    #expect(status("idle") == .idle)
    #expect(status("hibernated") == .idle)
    #expect(status("idle", history: 2) == .needInput)
    #expect(status("hibernated", history: 2) == .needInput)
    // A pending ask outranks whatever position arrives alongside it.
    #expect(status("running", approval: true) == .asking)
    #expect(status("idle", history: 1, question: true) == .asking)
}

@Test func puckStatusTonesMatchTheTerminalSupervisor() {
    #expect(PuckSessionStatusPolicy.tone(for: .asking) == .yellow)
    #expect(PuckSessionStatusPolicy.tone(for: .needInput) == .yellow)
    #expect(PuckSessionStatusPolicy.tone(for: .failed) == .red)
    #expect(PuckSessionStatusPolicy.tone(for: .idle) == .neutral)
    #expect(PuckSessionStatusPolicy.tone(for: .executing) == .blue)
}

@Test func puckStatusPolicyReadsTheDaemonSummary() throws {
    let summary = try PuckSessionSummary([
        "id": "shared", "provider": "codex", "account": "seat", "workspace": "/tmp",
        "cwd": "/tmp", "model": "model", "position": "idle", "history_items": 3
    ])
    #expect(summary.historyItems == 3)
    #expect(PuckSessionStatusPolicy.status(for: summary) == .needInput)

    // A daemon that predates the field reports no history.
    let older = try PuckSessionSummary([
        "id": "shared", "provider": "codex", "account": "seat", "workspace": "/tmp",
        "cwd": "/tmp", "model": "model", "position": "idle"
    ])
    #expect(older.historyItems == 0)
    #expect(PuckSessionStatusPolicy.status(for: older) == .idle)
}

@Test func puckBindingLeavesBlankFieldsToTheDaemon() {
    let blank = PuckSessionBinding(provider: "codex", account: "  ", model: "")
    #expect(blank.account == nil)
    #expect(blank.model == nil)

    let named = PuckSessionBinding(provider: "codex", account: " work ", model: "gpt-5.5\n")
    #expect(named.account == "work")
    #expect(named.model == "gpt-5.5")
}

@Test func puckBindingBrandsSessionsByTheirModelVendor() {
    #expect(PuckSessionBinding(provider: "codex").agentProvider == .codex)
    #expect(PuckSessionBinding(provider: "anthropic", account: "key", model: "claude-sonnet-4-5").agentProvider == .claude)
    #expect(PuckSessionBinding(provider: "gemini", account: "key", model: "gemini-2.5-pro").agentProvider == .gemini)
    #expect(PuckSessionBinding(provider: "opencode-go").agentProvider == .opencode)
    // OpenCode Go routes several vendors' models, so the model picks the brand,
    // as it does for a terminal OpenCode session.
    #expect(PuckSessionBinding(provider: "opencode-go", model: "glm-4.6").agentProvider == .zai)
    #expect(PuckSessionBinding(provider: "opencode-go", model: "kimi-k2").agentProvider == .opencode)
}

@Test func puckBindingValidationMatchesTheDaemonsRequirements() {
    #expect(PuckSessionBinding(provider: "codex").validationError == nil)
    #expect(PuckSessionBinding(provider: "opencode-go").validationError == nil)
    #expect(PuckSessionBinding(provider: "anthropic", account: "key", model: "claude-sonnet-4-5").validationError == nil)
    // Billed API providers have no default account or model.
    #expect(PuckSessionBinding(provider: "anthropic", model: "claude-sonnet-4-5").validationError != nil)
    #expect(PuckSessionBinding(provider: "gemini", account: "key").validationError != nil)
    #expect(PuckSessionBinding(provider: "unknown").validationError != nil)
}

@Test func snapshotsWrittenBeforeBackendsDecodeAsTerminalSessions() throws {
    let legacy = #"""
    {"id":"legacy","title":"Legacy","cwd":"/tmp","command":"codex","status":"running",
     "tone":"blue","createdAt":0,"updatedAt":0}
    """#
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(legacy.utf8))
    #expect(snapshot.backend == .terminal)
    #expect(snapshot.puck == nil)
}

@Test func puckSnapshotsKeepTheirRuntimeThroughCodingAndUpdates() throws {
    let snapshot = SessionSnapshot(
        id: "0f6c3a52-8c1e-4d7b-9a55-3b1f1d2e4c10",
        tmuxSessionName: nil,
        title: "project",
        reportedTitle: "fix the parser",
        cwd: "/tmp/project",
        command: "",
        status: .needInput,
        tone: .yellow,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100),
        backend: .puck,
        puck: PuckSessionBinding(provider: "opencode-go", account: "work", model: "glm-4.6")
    )

    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)

    let updated = snapshot.updating(status: .closed)
    #expect(updated.backend == .puck)
    #expect(updated.puck == snapshot.puck)
}
