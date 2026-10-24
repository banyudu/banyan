@testable import Banyan
import Foundation
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

@Test @MainActor func projectRootShortcutStartsATopLevelSession() throws {
    let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
    let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
    defer { store.flushPendingSessionSaves() }

    let parent = store.spawn(id: "parent", cwd: fixture.project.path, command: "", select: false)
    let selected = store.spawn(
        id: "selected",
        cwd: fixture.project.path,
        command: "",
        parentSessionID: parent.id,
        select: false
    )
    store.selectedSessionID = selected.id

    let spawned = try #require(store.spawnPaletteAgentSessionInProjectRoot())

    #expect(spawned.parentSessionID == nil)
}
