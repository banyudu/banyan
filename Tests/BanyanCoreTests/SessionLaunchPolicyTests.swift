import Testing
@testable import BanyanCore

@Test func siblingLaunchUsesOnlySupportedAgentRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
}
