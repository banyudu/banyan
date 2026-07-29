import Testing
@testable import BanyanCore

@Test func closePolicyConfirmsForActiveChildrenOrOngoingAgents() {
    #expect(SessionClosePolicy.requiresConfirmation(
        hasActiveChildren: true,
        status: .running,
        provider: nil
    ))
    #expect(SessionClosePolicy.requiresConfirmation(
        hasActiveChildren: false,
        status: .executing,
        provider: .codex
    ))
    #expect(!SessionClosePolicy.requiresConfirmation(
        hasActiveChildren: false,
        status: .completed,
        provider: .codex
    ))
}
