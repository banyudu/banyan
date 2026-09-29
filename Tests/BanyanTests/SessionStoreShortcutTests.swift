@testable import Banyan
import Testing
import BanyanCore

@Test func siblingShortcutUsesClaudeOrCodexRuntime() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .claude) == "claude")
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .codex) == "codex")
}

@Test func builtInDefaultsOfferTerminalCodexAndOptionalPuck() {
    #expect(NewSessionLaunch.builtInDefaults.map(\.id) == ["zsh", "claude", "codex", "codex-puck"])
    #expect(NewSessionLaunch.builtInDefaults.first { $0.id == "codex" }?.puck == nil)
    #expect(NewSessionLaunch.builtInDefaults.first { $0.id == "codex-puck" }?.puck == .init(provider: "codex"))
}

@Test func siblingShortcutFallsBackToTerminalForOtherRuntimes() {
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: nil).isEmpty)
    #expect(SessionLaunchPolicy.siblingRuntimeCommand(for: .gemini).isEmpty)
}
