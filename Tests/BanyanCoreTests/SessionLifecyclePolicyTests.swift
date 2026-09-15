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
        isRestored: true,
        isSuspended: false
    ))
    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: false,
        isRestored: false,
        isSuspended: false
    ))
}

@Test func lifecyclePolicyExcludesSuspendedSessionsFromSupervision() {
    // Parking leaves tmux and the agent running, so a parked session still looks
    // both started and restored. Only the explicit gate keeps it out of the tick.
    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: true,
        isRestored: true,
        isSuspended: true
    ))
    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: true,
        isRestored: false,
        isSuspended: true
    ))
    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: false,
        isRestored: true,
        isSuspended: true
    ))
}

@Test func lifecyclePolicyRecognizesOngoingSupportedAgentSessions() {
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .executing, provider: .codex))
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .needInput, provider: .claude))
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .executing, provider: .deepseek))
    #expect(SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .needInput, provider: .opencode))
    #expect(!SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .completed, provider: .codex))
    #expect(!SessionLifecyclePolicy.isOngoingCodingAgentSession(status: .executing, provider: .gemini))
}

@Test func needsAttentionCoversSessionsBlockedOnAHuman() {
    #expect(SessionLifecyclePolicy.needsAttention(status: .asking, isImportedHistory: false, isSuspended: false))
    #expect(SessionLifecyclePolicy.needsAttention(status: .needInput, isImportedHistory: false, isSuspended: false))
    #expect(SessionLifecyclePolicy.needsAttention(status: .failed, isImportedHistory: false, isSuspended: false))
}

@Test func needsAttentionSkipsQuietAndBusySessions() {
    #expect(!SessionLifecyclePolicy.needsAttention(status: .idle, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .running, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .executing, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .subagents, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .longRunningShell, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .review, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .completed, isImportedHistory: false, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .closed, isImportedHistory: false, isSuspended: false))
}

@Test func needsAttentionSkipsImportedHistory() {
    #expect(!SessionLifecyclePolicy.needsAttention(status: .asking, isImportedHistory: true, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .needInput, isImportedHistory: true, isSuspended: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .failed, isImportedHistory: true, isSuspended: false))
}

@Test func needsAttentionSkipsParkedSessions() {
    // Nothing observes a parked session, so the status it froze at would keep
    // it at the front of attention navigation until it was resumed.
    #expect(!SessionLifecyclePolicy.needsAttention(status: .asking, isImportedHistory: false, isSuspended: true))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .needInput, isImportedHistory: false, isSuspended: true))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .failed, isImportedHistory: false, isSuspended: true))
}

@Test func needsAttentionIsNarrowerThanWorkable() {
    // `idle` is the split: workable (you can type there) but not waiting on you.
    #expect(SessionLifecyclePolicy.isWorkable(status: .idle, isImportedHistory: false))
    #expect(!SessionLifecyclePolicy.needsAttention(status: .idle, isImportedHistory: false, isSuspended: false))
    // `failed` is the other half: not workable, but it does need a decision.
    #expect(!SessionLifecyclePolicy.isWorkable(status: .failed, isImportedHistory: false))
    #expect(SessionLifecyclePolicy.needsAttention(status: .failed, isImportedHistory: false, isSuspended: false))
}
