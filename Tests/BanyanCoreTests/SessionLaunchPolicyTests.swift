import Testing
@testable import BanyanCore

@Test func siblingLaunchUsesOnlySupportedAgentRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .opencode) == "opencode")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .deepseek) == "BANYAN_AGENT_PROVIDER=deepseek opencode")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
}

@Test func projectLaunchPrefersActiveSessionInTheGroup() {
    #expect(SessionLaunchPolicy.preferredSessionID(for: "active", in: ["first", "active"]) == "active")
}

@Test func projectLaunchFallsBackToFirstSessionOutsideTheGroup() {
    #expect(SessionLaunchPolicy.preferredSessionID(for: "other", in: ["first", "second"]) == "first")
    #expect(SessionLaunchPolicy.preferredSessionID(for: nil, in: ["first", "second"]) == "first")
    #expect(SessionLaunchPolicy.preferredSessionID(for: "other", in: []) == nil)
}
