import Foundation
import Testing
@testable import BanyanCore

@Test func lifecyclePolicyReopensLiveBackingSessionsAfterTerminalExit() {
    #expect(SessionLifecyclePolicy.statusAfterTerminalExit(
        currentStatus: .executing,
        hasBackingSession: true,
        exitCode: 1
    ) == .running)
    #expect(SessionLifecyclePolicy.statusAfterTerminalExit(
        currentStatus: .running,
        hasBackingSession: false,
        exitCode: 0
    ) == .completed)
    #expect(SessionLifecyclePolicy.statusAfterTerminalExit(
        currentStatus: .running,
        hasBackingSession: false,
        exitCode: nil
    ) == .failed)
    #expect(SessionLifecyclePolicy.statusAfterTerminalExit(
        currentStatus: .closed,
        hasBackingSession: true,
        exitCode: 0
    ) == nil)
}

@Test func lifecyclePolicyPreservesRestoredStatuses() {
    #expect(SessionLifecyclePolicy.restoredStatus(snapshotStatus: .closed) == .closed)
    #expect(SessionLifecyclePolicy.restoredStatus(snapshotStatus: .needInput) == .needInput)
}

@Test func lifecyclePolicyRequiresRecoveryOnlyForMissingActiveSessions() {
    #expect(SessionLifecyclePolicy.shouldMarkForRecovery(
        status: .running,
        tmuxSessionName: "banyan-1",
        liveTmuxSessionNames: []
    ))
    #expect(!SessionLifecyclePolicy.shouldMarkForRecovery(
        status: .running,
        tmuxSessionName: "banyan-1",
        liveTmuxSessionNames: ["banyan-1"]
    ))
    #expect(!SessionLifecyclePolicy.shouldMarkForRecovery(
        status: .completed,
        tmuxSessionName: "banyan-1",
        liveTmuxSessionNames: []
    ))
}

@Test func lifecyclePolicyIdentifiesWorkableSessions() {
    #expect(SessionLifecyclePolicy.isWorkable(status: .asking, isImportedHistory: false))
    #expect(SessionLifecyclePolicy.isWorkable(status: .needInput, isImportedHistory: false))
    #expect(!SessionLifecyclePolicy.isWorkable(status: .closed, isImportedHistory: false))
    #expect(!SessionLifecyclePolicy.isWorkable(status: .needInput, isImportedHistory: true))
}

@Test func lifecyclePolicyIncludesRestoredSessionsInSupervision() {
    #expect(SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: false,
        isRestored: true
    ))
    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: false,
        isRestored: false
    ))
}

@Test func lifecyclePolicyRecognizesOnlyOngoingCodexAndClaudeSessions() {
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .executing, provider: .codex))
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .needInput, provider: .claude))
    #expect(!SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .completed, provider: .codex))
    #expect(!SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .executing, provider: .gemini))
}
