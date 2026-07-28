import Foundation
import Testing
@testable import BanyanCore

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
