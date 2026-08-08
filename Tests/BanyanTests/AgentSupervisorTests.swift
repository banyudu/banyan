import Foundation
import BanyanCore
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
    let result = makeSupervisor(visibleText: "", processes: [agentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesVisibleAgentQuestionAsAsking() {
    let result = makeSupervisor(
        visibleText: "Can I edit these files?",
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .asking)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesRecentAgentActivityAsExecuting() {
    let result = makeSupervisor(
        visibleText: "Reading files\nEsc to interrupt",
        processes: [agentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "opencode",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorIgnoresStaleActivityTextOutsideRecentLines() {
    let staleText = (["Thinking"] + Array(repeating: "idle", count: 8)).joined(separator: "\n")

    let result = makeSupervisor(visibleText: staleText, processes: [agentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorTreatsExitedAgentPaneAsPlainShell() {
    // The agent was launched via a command that names it forever (e.g.
    // `banyan-worktree --claude …`), then exited back to a bare login shell. With
    // no agent process left alive, the session must read as a plain running shell
    // — not a stale idle agent — so the provider icon and handoff affordance drop.
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "zsh"),
        processes: [process(pid: 100, parentPID: 1, commandName: "/bin/zsh", arguments: "/bin/zsh -l", elapsed: 600)]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "banyan-worktree --claude ENG-7747",
        currentStatus: .needInput
    )

    #expect(result?.status == .running)
    #expect(result?.tone == .blue)
    #expect(result?.provider == nil)
}

@Test func supervisorTreatsFinishedCodexSummaryAsNeedInput() {
    // A completed Codex turn leaves a summary full of work words ("editing",
    // "Ran …", "Worked for 3m 38s") plus an idle input box in the visible tail.
    // None of that is a live turn, so it must not pin the session to `.executing`.
    let finishedText = [
        "  - Ran /design-review workflow before editing.",
        "  - Ran git diff --check.",
        "",
        "─ Worked for 3m 38s ─",
        "",
        "› Improve documentation in @filename",
        "",
        "  gpt-5.5 high fast · ~/dev/repo · Context 37% used"
    ].joined(separator: "\n")

    let result = makeSupervisor(visibleText: finishedText, processes: [agentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesLiveInterruptAffordanceAsExecuting() {
    // While a Codex turn is in flight it renders a live interrupt hint; that,
    // not a stray work word, is what keeps the session in `.executing`.
    let workingText = [
        "  Editing SessionStore.swift",
        "",
        "─ Working (0m 12s • Esc to interrupt) ─"
    ].joined(separator: "\n")

    let result = makeSupervisor(visibleText: workingText, processes: [agentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesExternalProcessAsExecuting() {
    let result = makeSupervisor(processes: [
        agentProcess("codex"),
        process(pid: 102, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 5)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesLongExternalProcessAsExecuting() {
    let result = makeSupervisor(processes: [
        agentProcess("codex"),
        process(pid: 102, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 121)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorIgnoresShellWrapperProcesses() {
    let result = makeSupervisor(processes: [
        process(commandName: "/bin/zsh", arguments: "zsh -lc codex", elapsed: 300),
        process(pid: 102, commandName: "/usr/bin/env", arguments: "env", elapsed: 300),
        process(pid: 103, commandName: "/opt/homebrew/bin/tmux", arguments: "tmux attach", elapsed: 300)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorDoesNotCountBanyanAgentWrapperAsSubagent() {
    let result = makeSupervisor(processes: [
        process(
            commandName: "/bin/bash",
            arguments: "/Users/banyudu/.agents/bin/banyan-agent-wrapper --agent claude -- claude",
            elapsed: 300
        ),
        process(
            commandName: "/usr/bin/tee",
            arguments: "tee -a /Users/banyudu/.agents/logs/banyan-agent-process.log",
            elapsed: 300
        ),
        agentProcess("claude", pid: 102)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "banyan-agent-wrapper --agent claude -- claude",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorTreatsPersistentMCPServerAsIdleNotExecuting() {
    // A coding agent keeps its MCP servers alive across turns as direct children.
    // They must not pin the session to `.executing` while it waits at the prompt.
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "claude"),
        processes: [
            process(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/banyudu/go/bin/axiom-mcp",
                arguments: "axiom-mcp -token redacted -url https://api.axiom.co",
                elapsed: 599
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorTreatsMCPServerWorkerSubtreeAsIdle() {
    // A node-based MCP server that forks a worker: the whole persistent subtree
    // is plumbing, not command execution.
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "claude"),
        processes: [
            process(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            process(pid: 101, parentPID: 100, commandName: "/usr/bin/node", arguments: "node mcp-server.js", elapsed: 599),
            process(pid: 102, parentPID: 101, commandName: "/usr/bin/node", arguments: "node worker.js", elapsed: 598)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorStillClassifiesCommandUnderShellAsExecuting() {
    // A genuine command execution runs under a shell wrapper (the agent's Bash
    // tool spawns `bash -c …`), so it must still read as executing.
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "claude"),
        processes: [
            process(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            process(pid: 101, parentPID: 100, commandName: "/bin/bash", arguments: "bash -c swift test", elapsed: 4),
            process(pid: 102, parentPID: 101, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 3)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
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

@Test func supervisorIgnoresCodexCodeModeHostAsAnAgent() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "node"),
        processes: [
            process(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/bin/codex",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/lib/codex",
                arguments: "/Users/example/lib/codex",
                elapsed: 5
            ),
            process(
                pid: 102,
                parentPID: 101,
                commandName: "/Users/example/lib/codex-code-mode-host",
                arguments: "/Users/example/lib/codex-code-mode-host",
                elapsed: 5
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorIgnoresCodexCuaRuntimeAsExternalWork() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "node"),
        processes: [
            process(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/bin/codex",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/lib/codex",
                arguments: "/Users/example/lib/codex",
                elapsed: 5
            ),
            process(
                pid: 102,
                parentPID: 101,
                commandName: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
                arguments: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
                elapsed: 5
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
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

@Test func supervisorDoesNotDoubleCountAgentForegroundCommandUnderLoginShell() {
    // tmux exposes the foreground command independently of `ps`. A login
    // shell running opencode therefore reports opencode in both places, but
    // this is one agent, not a parent plus subagent.
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "opencode"),
        processes: [
            process(pid: 100, parentPID: 1, commandName: "/bin/zsh", arguments: "/bin/zsh -l", elapsed: 300),
            process(pid: 101, parentPID: 100, commandName: "/opt/homebrew/bin/opencode", arguments: "opencode", elapsed: 5)
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "opencode",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorDoesNotCountShellLauncherAsSubagent() {
    let result = makeSupervisor(
        pane: pane(rootPID: 100, currentCommand: "zsh"),
        visibleText: "❯",
        processes: [
            process(
                pid: 100,
                parentPID: 1,
                commandName: "/bin/zsh",
                arguments: "/bin/zsh -lc claude",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "claude",
                arguments: "claude",
                elapsed: 5
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
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
    processes: [ProcessInfoRow] = []
) -> AgentSupervisor {
    AgentSupervisor(
        backend: FakeSupervisorBackend(pane: pane, sessionExists: sessionExists, visibleText: visibleText),
        processTable: ProcessTable(rows: processes)
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

/// A live agent process, child of the default pane's login shell (rootPID 100).
/// A running claude/codex/opencode always appears as such a child, so tests that
/// exercise an *active* agent session must include one — the launch command alone
/// no longer implies a live agent.
private func agentProcess(_ provider: String, pid: Int = 101) -> ProcessInfoRow {
    process(pid: pid, parentPID: 100, commandName: "/opt/homebrew/bin/\(provider)", arguments: provider, elapsed: 5)
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
