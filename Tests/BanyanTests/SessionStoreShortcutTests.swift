@testable import Banyan
import Testing
import BanyanCore

@Test func siblingShortcutUsesClaudeOrCodexRuntime() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
}

@Test func deepSeekDefaultLaunchUsesOpenCodeAndDeepSeekIdentity() {
    let launch = NewSessionLaunch.builtInDefaults.first { $0.id == "deepseek" }!
    #expect(launch.command == "BANYAN_AGENT_PROVIDER=deepseek opencode")
    #expect(launch.provider == .deepseek)
    #expect(launch.label == "DeepSeek")
}

@Test func siblingShortcutFallsBackToTerminalForOtherRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
}
