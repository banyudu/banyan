@testable import Banyan
import Testing
import BanyanCore

@Test func siblingShortcutUsesClaudeOrCodexRuntime() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
}

@Test func deepSeekNewSessionLaunchUsesOpenCodeAndDeepSeekIdentity() {
    #expect(NewSessionLaunch.deepseek.command == "BANYAN_AGENT_PROVIDER=deepseek opencode")
    #expect(NewSessionLaunch.deepseek.provider == .deepseek)
    #expect(NewSessionLaunch.deepseek.label == "DeepSeek")
}

@Test func siblingShortcutFallsBackToTerminalForOtherRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
}
