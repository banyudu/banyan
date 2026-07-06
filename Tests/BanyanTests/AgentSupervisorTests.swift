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
    let missingPaneResult = makeSupervisor(pane: nil, sessionExists: false).inspect(
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

@Test func supervisorIgnoresMissingPaneWhenTmuxSessionStillExists() {
    let result = makeSupervisor(pane: nil, sessionExists: true).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result == nil)
}

@Test func supervisorKeepsNonAgentSessionsRunning() {
    let result = makeSupervisor(pane: pane(currentCommand: "zsh")).inspect(
        tmuxSessionName: "shell",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .running)
    #expect(result?.tone == .blue)
    #expect(result?.currentPath == "/tmp")
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

@Test func supervisorTreatsNodeWrappedCodexAsSingleAgent() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "node"),
        processes: [
            process(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/banyudu/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/banyudu/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                arguments: "/Users/banyudu/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                elapsed: 5
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
    #expect(result?.provider?.rawValue == "codex")
}

@Test func supervisorDoesNotDoubleCountRootAgentProcess() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "codex"),
        processes: [
            process(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/codex", arguments: "codex", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorStillClassifiesNestedAgentWithNodeWrappedCodexAsSubagents() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "node"),
        processes: [
            process(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/banyudu/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/banyudu/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                arguments: "/Users/banyudu/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                elapsed: 5
            ),
            process(pid: 102, parentPID: 101, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "",
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
    #expect(result?.provider?.rawValue == "opencode")
}

@Test func supervisorDetectsCodexProviderFromNodeWrappedProcess() {
    let result = makeSupervisor(
        pane: pane(currentCommand: "node"),
        processes: [
            process(commandName: "node", arguments: "node /Users/banyudu/.nvm/versions/node/v24.4.1/bin/codex", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
    #expect(result?.provider?.rawValue == "codex")
}

@Test func supervisorCanDetectAgentFromPaneRootProcessArguments() {
    let processTable = ProcessTable(rows: [
        process(pid: 100, commandName: "/bin/zsh", arguments: "/bin/zsh /tmp/banyan-e2e/codex", elapsed: 5),
        process(pid: 101, parentPID: 100, commandName: "/bin/sleep", arguments: "sleep 240", elapsed: 5)
    ])
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "zsh"),
        processes: processTable.descendants(of: 100)
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "PATH=/tmp/banyan-e2e:$PATH codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supportedAgentCommandParsingAcceptsPathsAndRejectsNearMatches() {
    #expect(AgentSupervisor.isSupportedAgentCommand("codex --ask-for-approval never"))
    #expect(AgentSupervisor.isSupportedAgentCommand("/opt/homebrew/bin/claude"))
    #expect(AgentSupervisor.isSupportedAgentCommand("deepseek --model deepseek-chat"))
    #expect(AgentSupervisor.isSupportedAgentCommand("opencode"))
    #expect(!AgentSupervisor.isSupportedAgentCommand("my-codex-wrapper"))
    #expect(!AgentSupervisor.isSupportedAgentCommand(""))
}

@Test func processInfoLoaderReadsPlatformProcessTable() {
    let rows = ProcessInfoRow.load()

    #expect(!rows.isEmpty)
    #expect(rows.contains { $0.pid > 0 && $0.elapsed >= 0 && !$0.commandName.isEmpty })
}

private func makeSupervisor(
    pane: TmuxPaneSnapshot? = pane(),
    sessionExists: Bool = true,
    visibleText: String = "",
    processes: [ProcessInfoRow] = [],
    longRunningThreshold: TimeInterval = 120
) -> AgentSupervisor {
    AgentSupervisor(
        backend: FakeSupervisorBackend(pane: pane, sessionExists: sessionExists, visibleText: visibleText),
        longRunningThreshold: longRunningThreshold,
        processDescendants: { _ in processes }
    )
}

private func pane(
    rootPID: Int = 100,
    currentCommand: String = "zsh",
    isDead: Bool = false
) -> TmuxPaneSnapshot {
    TmuxPaneSnapshot(
        paneID: "%1",
        rootPID: rootPID,
        currentCommand: currentCommand,
        currentPath: "/tmp",
        isDead: isDead,
        isInMode: false
    )
}

private func process(
    pid: Int = 101,
    parentPID: Int = 100,
    commandName: String,
    arguments: String,
    elapsed: TimeInterval
) -> ProcessInfoRow {
    ProcessInfoRow(
        pid: pid,
        parentPID: parentPID,
        state: "S",
        elapsed: elapsed,
        commandName: commandName,
        arguments: arguments
    )
}

private struct FakeSupervisorBackend: AgentSupervisorBackend {
    var pane: TmuxPaneSnapshot?
    var sessionExists: Bool
    var visibleText: String

    func hasSession(named name: String) -> Bool {
        sessionExists
    }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        pane
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String {
        visibleText
    }
}
