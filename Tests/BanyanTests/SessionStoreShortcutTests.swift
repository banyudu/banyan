@testable import Banyan
import Testing
import BanyanCore

@Test func siblingShortcutUsesClaudeOrCodexRuntime() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
}

@Test func builtInDefaultsContainOnlyZshClaudeAndCodex() {
    #expect(NewSessionLaunch.builtInDefaults.map(\.id) == ["zsh", "claude", "codex"])
}

@Test func siblingShortcutFallsBackToTerminalForOtherRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
}
