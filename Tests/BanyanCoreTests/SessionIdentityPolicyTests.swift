import Testing
@testable import BanyanCore

@Test func sessionIdentityPolicyUsesStableTmuxName() {
    #expect(SessionIdentityPolicy.sessionName(for: "session-1") == "banyan-session-1")
    #expect(TmuxBackend.sessionName(for: "session-1") == SessionIdentityPolicy.sessionName(for: "session-1"))
}

@Test func sessionIdentitySanitizesIDsWithoutChangingAllowedCharacters() {
    #expect(SessionIdentityPolicy.sanitizedID("  feature/sidebar  ") == "feature-sidebar")
    #expect(SessionIdentityPolicy.sanitizedID("!!!") == "session")
    #expect(SessionIdentityPolicy.sanitizedID("session_2") == "session_2")
}
