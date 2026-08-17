import Testing
@testable import BanyanCore

@Test func appServerModeUsesInteractiveRemoteTUIInsteadOfExec() {
    let command = AgentLaunchCommand.command(
        provider: .codex,
        prompt: "implement remote control",
        codexLaunchMode: .appServer
    )

    #expect(command == "'codex' 'remote-control' 'start' && exec 'codex' '--remote' 'unix://' 'implement remote control'")
    #expect(!command.contains("'exec'"))
    #expect(CodexAppServerLaunch.isAppServerCommand(command))
}

@Test func appServerModeResumesTheSameThreadThroughTheLocalDaemon() {
    let command = CodexAppServerLaunch.resumeCommand(
        sourceID: "thread-123",
        cwd: "/tmp/project with spaces",
        prompt: "continue"
    )

    #expect(command == "'codex' 'remote-control' 'start' && exec 'codex' '--remote' 'unix://' 'resume' '-C' '/tmp/project with spaces' 'thread-123' 'continue'")
}

@Test func directModeKeepsTheExistingInteractiveCodexCommand() {
    #expect(AgentLaunchCommand.command(provider: .codex, prompt: "continue") == "'codex' 'continue'")
}

@Test func appServerModeCanUpgradeBanyansCanonicalControlCommand() {
    let direct = AgentLaunchCommand.command(provider: .codex, prompt: "continue")

    #expect(CodexAppServerLaunch.upgradedDirectCommand(direct) == "'codex' 'remote-control' 'start' && exec 'codex' '--remote' 'unix://' 'continue'")
    #expect(CodexAppServerLaunch.upgradedDirectCommand("codex --custom-wrapper") == nil)
}
