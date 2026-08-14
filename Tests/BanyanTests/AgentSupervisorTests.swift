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

@Test func supervisorClassifiesOpenCodeBareInterruptHintAsExecuting() {
    // OpenCode renders its live interrupt affordance as "esc interrupt" (no
    // "to") in the bottom status bar while a turn is in flight, and swaps it
    // for the cwd line when idle. Without the bare hint the session fell
    // through to `.needInput` (✋) even while actively working.
    let workingText = [
        "",
        "",
        "",
        "  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go",
        "  ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt  32.6K (3%) · $0.00  ctrl+p commands    • OpenCode 1.18.18"
    ].joined(separator: "\n")

    let result = makeSupervisor(
        visibleText: workingText,
        processes: [agentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "BANYAN_AGENT_PROVIDER=deepseek opencode",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
    #expect(result?.provider == .deepseek)
}

@Test func supervisorTreatsIdleOpenCodeFooterAsNeedInput() {
    // When an OpenCode turn finishes, the status bar swaps the live
    // "esc interrupt" hint for the cwd line. The bare-hint match added for
    // executing detection must not leak into this idle state and pin the
    // session to `.executing`.
    let idleText = [
        "",
        "",
        "  > Fixed the agent status detection",
        "",
        "  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go",
        "  /Users/example/dev/repo  135.5K (14%) · $0.02  ctrl+p commands    • OpenCode 1.18.18"
    ].joined(separator: "\n")

    let result = makeSupervisor(
        visibleText: idleText,
        processes: [agentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "BANYAN_AGENT_PROVIDER=deepseek opencode",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
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
            arguments: "/Users/example/.agents/bin/banyan-agent-wrapper --agent claude -- claude",
            elapsed: 300
        ),
        process(
            commandName: "/usr/bin/tee",
            arguments: "tee -a /Users/example/.agents/logs/banyan-agent-process.log",
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
                arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            process(
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
                arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex",
                elapsed: 5
            ),
            process(
                pid: 101,
                parentPID: 100,
                commandName: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
                arguments: "/Users/example/.nvm/versions/node/v24.4.1/lib/node_modules/@openai/codex/bin/codex",
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
            process(commandName: "node", arguments: "node /Users/example/.nvm/versions/node/v24.4.1/bin/codex", elapsed: 5)
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

// Captures below are real `tmux capture-pane -p -J -S -60` output, trimmed to
// pane width, so the idle heuristic is pinned to what the agents actually render.

@Test func supervisorClassifiesFreshlyLaunchedClaudePaneAsIdle() {
    let result = makeSupervisor(
        visibleText: freshClaudePane,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .idle)
    #expect(result?.tone == .neutral)
}

@Test func supervisorClassifiesFreshlyLaunchedCodexPaneAsIdle() {
    let freshText = [
        "╭──────────────────────────────────────────────────────────╮",
        "│ >_ OpenAI Codex (v0.147.0)                               │",
        "│                                                          │",
        "│ model:       gpt-5.6-luna medium   fast   /model to cha… │",
        "│ directory:   ~/dev/yudu/banyan                           │",
        "╰──────────────────────────────────────────────────────────╯",
        "",
        "  Tip: Try the Desktop app. Run 'codex app'",
        "",
        "› Implement {feature}",
        "",
        "  gpt-5.6-luna medium fast · ~/dev/yudu/banyan · Context 0% used"
    ].joined(separator: "\n")

    let result = makeSupervisor(visibleText: freshText, processes: [agentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .idle)
    #expect(result?.tone == .neutral)
}

@Test func supervisorTreatsClearedConversationAsIdle() {
    // `/clear` repaints the welcome box and leaves only its own echoed command
    // behind, which is the state a user expects to read as "nothing to see here".
    let clearedText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: "❯ /clear\n\n─────────────────────────────────────── ↯ ─"
    )

    let result = makeSupervisor(
        visibleText: clearedText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .needInput
    )

    #expect(result?.status == .idle)
}

@Test func supervisorKeepsSessionIdleThroughBackgroundHeartbeatTurn() {
    // A cache-warm ping fires itself on a timer and answers itself. It leaves a
    // transcript behind but no result the user is waiting to read, so a session
    // that was empty must stay empty across one.
    let heartbeatText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ /clear",
            "",
            "✻ Claude resuming /loop wakeup (Aug 11 3:39pm)",
            "",
            "⏺ CronCreate(21 16 11 8 *: __cache-warm-ping__)",
            "  ⎿  Scheduled a03428ac (21 16 11 8 *)",
            "",
            "⏺ ok",
            "",
            "✻ Cogitated for 8s",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeSupervisor(
        visibleText: heartbeatText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .idle)
}

@Test func supervisorStillReportsUserWorkThatPrecededAHeartbeat() {
    // The heartbeat discount applies to the agent's own rows, never to a prompt
    // the user typed — otherwise a real answer would be hidden by the next ping.
    let mixedText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ summarize the failing test",
            "",
            "⏺ The fixture path is wrong; fix is a one-liner.",
            "",
            "✻ Claude resuming /loop wakeup (Aug 11 3:39pm)",
            "",
            "⏺ CronCreate(21 16 11 8 *: __cache-warm-ping__)",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeSupervisor(
        visibleText: mixedText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
}

@Test func supervisorReportsLoopWorkThatIsNotAHeartbeat() {
    // A `/loop` that does real work is machine-triggered too, but its result is
    // worth reading — only the heartbeat's own sentinel silences a turn.
    let loopText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "✻ Claude resuming /loop wakeup (Aug 11 3:39pm)",
            "",
            "⏺ CI failed on main: 3 tests broken in SessionStore.",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeSupervisor(
        visibleText: loopText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
}

@Test func supervisorClassifiesCompactClaudeHeaderPaneAsIdle() {
    // A plain `claude` launch prints a compact header instead of the welcome box:
    // three logo rows that carry the model and cwd text themselves. Those rows are
    // header chrome, not conversation, even though they hold real words.
    let compactText = [
        "➜  ~ claude",
        " ▐▛███▜▌   Claude Code v2.1.227",
        "▝▜█████▛▘  Opus 5 (1M context) with medium effort · Claude Max",
        "  ▘▘ ▝▝    /Users/banyudu",
        "",
        "❯ /clear",
        "",
        "───────────────────────────────────────────",
        "❯",
        "───────────────────────────────────────────",
        "  Opus 5 (1M context) | ~",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
    ].joined(separator: "\n")

    let result = makeSupervisor(
        visibleText: compactText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .idle)
}

@Test func supervisorTreatsClearedConversationAsIdleDespiteQuestionInOldScrollback() {
    // `/clear` wipes the screen but not tmux's scrollback, so the captured window
    // still holds the previous conversation. A question phrase up there must not
    // outrank the empty prompt below the redrawn banner — this pinned a cleared
    // session to `.asking` indefinitely.
    let clearedText = ([
        "⏺ User answered Claude's questions:",
        "  ⎿  · Which branch should I merge to main and deploy? → yudu/eng-8936",
        "",
        "⏺ Merged as c7395cd. Now the VM:",
        ""
    ] + [freshClaudePane]).joined(separator: "\n")
        .replacingOccurrences(
            of: "─────────────────────────────────────── ↯ ─",
            with: "❯ /clear\n\n─────────────────────────────────────── ↯ ─"
        )

    let result = makeSupervisor(
        visibleText: clearedText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .asking
    )

    #expect(result?.status == .idle)
}

@Test func supervisorStillClassifiesLiveQuestionBelowBannerAsAsking() {
    // The reordering above must not swallow a genuine question asked in a session
    // whose banner is still on screen.
    let askingText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ ship it",
            "",
            "⏺ Do you want me to force-push over the remote branch?",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeSupervisor(
        visibleText: askingText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .asking)
}

@Test func supervisorKeepsFinishedTurnAsNeedInputWhileBannerLingers() {
    // The welcome box stays inside the captured window for the first few turns,
    // so a banner match alone must never be enough to call a session untouched.
    let finishedText = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ hi, reply with just the word ok",
            "",
            "⏺ ok",
            "",
            "✻ Cooked for 10s",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeSupervisor(
        visibleText: finishedText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorTreatsPaneWithoutBannerAsNeedInput() {
    // Once the banner scrolls out of the window there is no evidence the session
    // is untouched, so the attention-raising default has to win.
    let bannerlessText = [
        "",
        "─────────────────────────────────────── ↯ ─",
        "❯",
        "───────────────────────────────────────────",
        "  Opus 5 (1M context) | 4% ctx | ~/dev/yudu/banyan | main"
    ].joined(separator: "\n")

    let result = makeSupervisor(
        visibleText: bannerlessText,
        processes: [agentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
}

private let freshClaudePane = [
    "╭─── Claude Code v2.1.227 ─────────────────────────────╮",
    "│                            │ Tips for getting started │",
    "│      Welcome back Yudu!    │ Run /init to create a    │",
    "│                            │ CLAUDE.md file           │",
    "│         ▐▛███▜▌            │ What's new               │",
    "│      ~/dev/yudu/banyan     │ /release-notes for more  │",
    "╰──────────────────────────────────────────────────────╯",
    "",
    "",
    "─────────────────────────────────────── ↯ ─",
    "❯",
    "───────────────────────────────────────────",
    "  Opus 5 (1M context) | ~/dev/yudu/banyan | main",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
].joined(separator: "\n")

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
