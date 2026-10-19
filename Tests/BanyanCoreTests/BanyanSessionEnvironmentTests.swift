import Testing
@testable import BanyanCore

@Test func appEnvironmentDropsInheritedSessionAndTmuxContext() {
    let environment = BanyanSessionEnvironment.appEnvironment(from: [
        "BANYAN_SESSION_ID": "old-session",
        "BANYAN_PARENT_SESSION_ID": "old-parent",
        "TMUX": "/tmp/tmux-fixture/socket,100,0",
        "TMUX_PANE": "%1",
        "PATH": "/usr/bin",
        "BANYAN_TITLE_COMMAND": "title-command"
    ])
    #expect(environment == ["PATH": "/usr/bin", "BANYAN_TITLE_COMMAND": "title-command"])
    #expect(BanyanSessionEnvironment.parentSessionID(from: environment) == nil)
}

@Test func appEnvironmentPreservesExplicitSessionContextForSubsequentChildren() {
    var environment = BanyanSessionEnvironment.appEnvironment(from: ["PATH": "/usr/bin"])
    environment[BanyanSessionEnvironment.sessionIDKey] = "new-session"
    #expect(BanyanSessionEnvironment.parentSessionID(from: environment) == "new-session")
}

@Test func sessionEnvironmentPrefersParentOverrideOverSessionID() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.parentSessionIDKey: "PARENT-1",
        BanyanSessionEnvironment.sessionIDKey: "SELF-1",
    ]) == "PARENT-1")
}

@Test func sessionEnvironmentFallsBackToSessionID() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "TASK-123",
    ]) == "TASK-123")
}

@Test func sessionEnvironmentIgnoresBlankValues() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "   ",
    ]) == nil)
    #expect(BanyanSessionEnvironment.parentSessionID(from: [:]) == nil)
}

@Test func sessionEnvironmentTrimsValues() {
    #expect(BanyanSessionEnvironment.parentSessionID(from: [
        BanyanSessionEnvironment.sessionIDKey: "  TASK-123  ",
    ]) == "TASK-123")
}

@Test func sessionIDRoundTripsThroughTmuxSessionName() {
    let name = SessionIdentityPolicy.sessionName(for: "TASK-123")
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: name) == "TASK-123")
}

@Test func sessionIDFromTmuxSessionNameRejectsForeignSessions() {
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "other-session") == nil)
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "banyan-") == nil)
    #expect(BanyanSessionEnvironment.sessionID(fromTmuxSessionName: "") == nil)
}
