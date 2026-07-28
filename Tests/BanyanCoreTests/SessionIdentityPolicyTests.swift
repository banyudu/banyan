import Testing
@testable import BanyanCore

@Test func sessionIdentityPolicyUsesStableTmuxName() {
    #expect(SessionIdentityPolicy.sessionName(for: "session-1") == "banyan-session-1")
    #expect(TmuxBackend.sessionName(for: "session-1") == SessionIdentityPolicy.sessionName(for: "session-1"))
}
