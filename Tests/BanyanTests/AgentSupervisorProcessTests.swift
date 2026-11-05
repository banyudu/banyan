import Foundation
import BanyanCore
import Testing
@testable import Banyan


@Test func supervisorClassifiesExternalProcessAsExecuting() {
    let result = makeTestSupervisor(processes: [
        supervisorTestAgentProcess("codex"),
        supervisorTestProcess(pid: 102, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 5)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesLongExternalProcessAsExecuting() {
    let result = makeTestSupervisor(processes: [
        supervisorTestAgentProcess("codex"),
        supervisorTestProcess(pid: 102, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 121)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorIgnoresShellWrapperProcesses() {
    let result = makeTestSupervisor(processes: [
        supervisorTestProcess(commandName: "/bin/zsh", arguments: "zsh -lc codex", elapsed: 300),
        supervisorTestProcess(pid: 102, commandName: "/usr/bin/env", arguments: "env", elapsed: 300),
        supervisorTestProcess(pid: 103, commandName: "/opt/homebrew/bin/tmux", arguments: "tmux attach", elapsed: 300)
    ]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorDoesNotCountBanyanAgentWrapperAsSubagent() {
    let result = makeTestSupervisor(processes: [
        supervisorTestProcess(
            commandName: "/bin/bash",
            arguments: "/Users/example/.agents/bin/banyan-agent-wrapper --agent claude -- claude",
            elapsed: 300
        ),
        supervisorTestProcess(
            commandName: "/usr/bin/tee",
            arguments: "tee -a /Users/example/.agents/logs/banyan-agent-process.log",
            elapsed: 300
        ),
        supervisorTestAgentProcess("claude", pid: 102)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "claude"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/go/bin/axiom-mcp",
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "claude"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            supervisorTestProcess(pid: 101, parentPID: 100, commandName: "/usr/bin/node", arguments: "node mcp-server.js", elapsed: 599),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/usr/bin/node", arguments: "node worker.js", elapsed: 598)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "claude"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            supervisorTestProcess(pid: 101, parentPID: 100, commandName: "/bin/bash", arguments: "bash -c swift test", elapsed: 4),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 3)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(currentCommand: "codex"),
        processes: [
            supervisorTestProcess(commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 5)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "node"),
        processes: [
            supervisorTestProcess(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                arguments: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "node"),
        processes: [
            supervisorTestProcess(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/bin/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/lib/codex",
                arguments: "/Users/example/lib/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "node"),
        processes: [
            supervisorTestProcess(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/bin/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/lib/codex",
                arguments: "/Users/example/lib/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "codex"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/codex", arguments: "codex", elapsed: 5)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "opencode"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/bin/zsh", arguments: "/bin/zsh -l", elapsed: 300),
            supervisorTestProcess(pid: 101, parentPID: 100, commandName: "/opt/homebrew/bin/opencode", arguments: "opencode", elapsed: 5)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "zsh"),
        visibleText: "❯",
        processes: [
            supervisorTestProcess(
                pid: 100,
                parentPID: 1,
                commandName: "/bin/zsh",
                arguments: "/bin/zsh -lc claude",
                elapsed: 5
            ),
            supervisorTestProcess(
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "node"),
        processes: [
            supervisorTestProcess(
                pid: 100,
                parentPID: 1,
                commandName: "node",
                arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                arguments: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                elapsed: 5
            ),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 5)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(currentCommand: "node"),
        processes: [
            supervisorTestProcess(commandName: "/opt/homebrew/bin/opencode", arguments: "opencode", elapsed: 5)
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(currentCommand: "node"),
        processes: [
            supervisorTestProcess(commandName: "node", arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex", elapsed: 5)
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

@Test func supervisorIgnoresUnreapedChildrenWhenLookingForWork() {
    // A defunct child is not a command in flight. Counting one as work pinned the
    // session to `.executing`, which the backoff policy then exempts from ever
    // slowing down — so a single unreaped process kept the supervisor at its
    // fastest cadence indefinitely.
    let supervisor = makeTestSupervisor(
        visibleText: "❯ ",
        processes: [
            supervisorTestAgentProcess("claude"),
            supervisorTestProcess(pid: 102, parentPID: 101, commandName: "/bin/cat", arguments: "cat", elapsed: 3, state: "Z")
        ]
    )

    let result = supervisor.inspect(
        tmuxSessionName: "banyan-session-1",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status != .executing)
}
