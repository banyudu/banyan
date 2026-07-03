import Foundation
import Testing
@testable import Banyan

@Test func supervisorIgnoresClosedSessions() {
    let result = makeSupervisor().inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .closed
    )

    #expect(result == nil)
}

@Test func supervisorMarksMissingOrDeadPaneClosed() {
    let missingPaneResult = makeSupervisor(pane: nil).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )
    let deadPaneResult = makeSupervisor(pane: pane(isDead: true)).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(missingPaneResult?.status == .closed)
    #expect(missingPaneResult?.tone == .neutral)
    #expect(deadPaneResult?.status == .closed)
    #expect(deadPaneResult?.tone == .neutral)
}

@Test func supervisorKeepsNonAgentSessionsRunning() {
    let result = makeSupervisor(pane: pane(currentCommand: "zsh")).inspect(
        tmuxSessionName: "shell",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .running)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesAgentWaitingForInput() {
    let result = makeSupervisor(visibleText: "").inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesVisibleAgentQuestionAsAsking() {
    let result = makeSupervisor(visibleText: "Can I edit these files?").inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .asking)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesRecentAgentActivityAsExecuting() {
    let result = makeSupervisor(visibleText: "Reading files\nEsc to interrupt").inspect(
        tmuxSessionName: "agent",
        launchCommand: "opencode",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorIgnoresStaleActivityTextOutsideRecentLines() {
    let staleText = (["Thinking"] + Array(repeating: "idle", count: 8)).joined(separator: "\n")

    let result = makeSupervisor(visibleText: staleText).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesExternalProcessAsExecuting() {
    let result = makeSupervisor(processes: [
        process(commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 5)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesLongExternalProcessAsLongRunningShell() {
    let result = makeSupervisor(processes: [
        process(commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 121)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .longRunningShell)
    #expect(result?.tone == .yellow)
}

@Test func supervisorIgnoresShellWrapperProcesses() {
    let result = makeSupervisor(processes: [
        process(commandName: "/bin/zsh", arguments: "zsh -lc codex", elapsed: 300),
        process(commandName: "/usr/bin/env", arguments: "env", elapsed: 300),
        process(commandName: "/opt/homebrew/bin/tmux", arguments: "tmux attach", elapsed: 300)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesMultipleAgentProcessesAsSubagents() {
    let result = makeSupervisor(
        pane: pane(currentCommand: "codex"),
        processes: [
            process(commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .subagents)
    #expect(result?.tone == .purple)
}

@Test func supervisorCanDetectAgentFromDescendantProcess() {
    let result = makeSupervisor(
        pane: pane(currentCommand: "node"),
        processes: [
            process(commandName: "/opt/homebrew/bin/opencode", arguments: "opencode", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "npm run agent",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supportedAgentCommandParsingAcceptsPathsAndRejectsNearMatches() {
    #expect(AgentSupervisor.isSupportedAgentCommand("codex --ask-for-approval never"))
    #expect(AgentSupervisor.isSupportedAgentCommand("/opt/homebrew/bin/claude"))
    #expect(AgentSupervisor.isSupportedAgentCommand("opencode"))
    #expect(!AgentSupervisor.isSupportedAgentCommand("my-codex-wrapper"))
    #expect(!AgentSupervisor.isSupportedAgentCommand(""))
}

private func makeSupervisor(
    pane: TmuxPaneSnapshot? = pane(),
    visibleText: String = "",
    processes: [ProcessInfoRow] = [],
    longRunningThreshold: TimeInterval = 120
) -> AgentSupervisor {
    AgentSupervisor(
        backend: FakeSupervisorBackend(pane: pane, visibleText: visibleText),
        longRunningThreshold: longRunningThreshold,
        processDescendants: { _ in processes }
    )
}

private func pane(
    currentCommand: String = "zsh",
    isDead: Bool = false
) -> TmuxPaneSnapshot {
    TmuxPaneSnapshot(
        paneID: "%1",
        rootPID: 100,
        currentCommand: currentCommand,
        currentPath: "/tmp",
        isDead: isDead,
        isInMode: false
    )
}

private func process(
    commandName: String,
    arguments: String,
    elapsed: TimeInterval
) -> ProcessInfoRow {
    ProcessInfoRow(
        pid: 101,
        parentPID: 100,
        state: "S",
        elapsed: elapsed,
        commandName: commandName,
        arguments: arguments
    )
}

private struct FakeSupervisorBackend: AgentSupervisorBackend {
    var pane: TmuxPaneSnapshot?
    var visibleText: String

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        pane
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        visibleText
    }
}
