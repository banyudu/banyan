@testable import Banyan
import Testing
import BanyanCore

@Test func siblingShortcutUsesClaudeOrCodexRuntime() {
    #expect(SessionStore.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionStore.siblingRuntimeCommand(for: .codex) == "codex")
}

@Test func siblingShortcutFallsBackToTerminalForOtherRuntimes() {
    #expect(SessionStore.siblingRuntimeCommand(for: nil).isEmpty)
    #expect(SessionStore.siblingRuntimeCommand(for: .gemini).isEmpty)
}
