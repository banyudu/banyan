import Testing
@testable import BanyanCore

@Test func sessionEnvironmentPrefersParentOverrideOverSessionID() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.parentSessionIDKey: "PARENT-1",
        BanyanSessionEnvironment.sessionIDKey: "SELF-1",
    ]) == "PARENT-1")
}

@Test func sessionEnvironmentFallsBackToSessionID() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "ENG-123",
    ]) == "ENG-123")
}

@Test func sessionEnvironmentIgnoresBlankValues() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "   ",
    ]) == nil)
    #expect(BanyanSessionEnvironment.parentSessionID(from: [:]) == nil)
}

@Test func sessionEnvironmentTrimsValues() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "  ENG-123  ",
    ]) == "ENG-123")
}

@Test func sessionIDRoundTripsThroughTmuxSessionName() {
    let name = SessionIdentityPolicy.sessionName(for: "ENG-123")
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: name) == "ENG-123")
}

@Test func sessionIDFromTmuxSessionNameRejectsForeignSessions() {
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "other-session") == nil)
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "banyan-") == nil)
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "") == nil)
}
