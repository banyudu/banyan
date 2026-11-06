import Foundation
import BanyanCore
import Testing
@testable import Banyan


@Test func supervisorIgnoresClosedSessions() {
    let result = makeTestSupervisor().inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .closed
    )

    #expect(result == nil)
}

@Test func supervisorMarksMissingOrDeadPaneClosed() {
    let missingPaneResult = makeTestSupervisor(pane: nil, sessionExists: false).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )
    let deadPaneResult = makeTestSupervisor(pane: supervisorTestPane(isDead: true)).inspect(
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
    let result = makeTestSupervisor(pane: nil, sessionExists: true).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result == nil)
}

@Test func supervisorKeepsNonAgentSessionsRunning() {
    let result = makeTestSupervisor(pane: supervisorTestPane(currentCommand: "zsh")).inspect(
        tmuxSessionName: "shell",
        launchCommand: "",
        currentStatus: .running
    )

    #expect(result?.status == .running)
    #expect(result?.tone == .blue)
    #expect(result?.currentPath == "/tmp")
}

@Test func supervisorClassifiesAgentWaitingForInput() {
    let result = makeTestSupervisor(visibleText: "", processes: [supervisorTestAgentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesVisibleAgentQuestionAsAsking() {
    let result = makeTestSupervisor(
        visibleText: "Can I edit these files?",
        processes: [supervisorTestAgentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .asking)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesRecentAgentActivityAsExecuting() {
    let result = makeTestSupervisor(
        visibleText: "Reading files\nEsc to interrupt",
        processes: [supervisorTestAgentProcess("opencode")]
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
    // through to `.needInput` even while actively working.
    let workingText = [
        "",
        "",
        "",
        "  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go",
        "  ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt  32.6K (3%) · $0.00  ctrl+p commands    • OpenCode 1.18.18"
    ].joined(separator: "\n")

    let result = makeTestSupervisor(
        visibleText: workingText,
        processes: [supervisorTestAgentProcess("opencode")]
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

    let result = makeTestSupervisor(
        visibleText: idleText,
        processes: [supervisorTestAgentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "BANYAN_AGENT_PROVIDER=deepseek opencode",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorClassifiesFreshlyLaunchedOpenCodePaneAsIdle() {
    // Fresh OpenCode has no text banner. Its logo is followed by the empty
    // input's `Ask anything...` placeholder, which disappears after a turn.
    let result = makeTestSupervisor(
        visibleText: supervisorFreshOpenCodePane,
        processes: [supervisorTestAgentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "opencode",
        currentStatus: .running
    )

    #expect(result?.status == .idle)
    #expect(result?.tone == .neutral)
}

@Test func supervisorClassifiesClearedOpenCodePaneAsIdle() {
    // tmux retains old scrollback after `/clear`; the freshly painted OpenCode
    // logo and empty-input placeholder must still win over an old question.
    let clearedText = ([
        "Do you want to apply the previous patch?",
        ""
    ] + [supervisorFreshOpenCodePane]).joined(separator: "\n")

    let result = makeTestSupervisor(
        visibleText: clearedText,
        processes: [supervisorTestAgentProcess("opencode")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "opencode",
        currentStatus: .asking
    )

    #expect(result?.status == .idle)
    #expect(result?.tone == .neutral)
}

@Test func supervisorIgnoresStaleActivityTextOutsideRecentLines() {
    let staleText = (["Thinking"] + Array(repeating: "idle", count: 8)).joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: staleText, processes: [supervisorTestAgentProcess("codex")]).inspect(
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
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "zsh"),
        processes: [supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/bin/zsh", arguments: "/bin/zsh -l", elapsed: 600)]
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

    let result = makeTestSupervisor(visibleText: finishedText, processes: [supervisorTestAgentProcess("codex")]).inspect(
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

    let result = makeTestSupervisor(visibleText: workingText, processes: [supervisorTestAgentProcess("codex")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "codex",
        currentStatus: .running
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesLiveElapsedCounterAsExecuting() {
    // Claude prints no interrupt hint. A turn in flight is visible only as a
    // spinner line with a live elapsed counter, whose gerund is randomized per
    // turn and whose ellipsis sits mid-line — so neither the verb list nor a
    // trailing-ellipsis test can see it, and the session used to fall through to
    // `.needInput` and offer handoff while the agent was still working.
    let workingText = [
        "⏺ Bash(rg -n 'claimedByAnotherCollector' src/telemetry.ts)",
        "  ⎿  … +27 lines (ctrl+o to expand)",
        "",
        "✳ Whirlpooling… (5m 55s · ↓ 21.2k tokens)",
        "",
        "──────────────────────────────────────────────",
        "❯ ",
        "──────────────────────────────────────────────",
        "  Opus 5 (1M context) | 14% ctx | …/repo | TASK-123 | wk 2%",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: workingText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .needInput
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorClassifiesElapsedCounterWithRotatingHintAsExecuting() {
    // The counter's trailing segment rotates through hints instead of a fixed
    // interrupt affordance, so the elapsed token is the only stable part.
    let workingText = [
        "✻ Whirlpooling… (3m 16s · ↓ 9.0k tokens · thinking more with max effort)",
        "❯ "
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: workingText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .needInput
    )

    #expect(result?.status == .executing)
}

@Test func supervisorDoesNotReadIdleStatusFooterAsLiveCounter() {
    // The status footer ends in a parenthetical and carries an elided path, but
    // `(1M context)` names a model window, not elapsed seconds.
    let idleText = [
        "⏺ Fixed the agent status detection.",
        "",
        "──────────────────────────────────────────────",
        "❯ ",
        "──────────────────────────────────────────────",
        "  …/repo | TASK-123 | Opus 5 (1M context)"
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: idleText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorDoesNotReadElidedToolCallAsLiveCounter() {
    // A finished tool call can end in `)` and mention a duration, but its
    // ellipsis marks elided arguments *inside* the group, not a spinner.
    let idleText = [
        "⏺ Bash(for host in a b c; do curl --max-time 30s \"$host\" …)",
        "  ⎿  … +12 lines (ctrl+o to expand)",
        "",
        "❯ "
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: idleText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
}

@Test func supervisorKeepsPerTurnSleepAssertionAsExecuting() {
    // Claude holds a sleep assertion only while a turn is in flight, as a
    // `caffeinate -i -t 300` child it re-leases every five minutes and drops when
    // the turn ends. It looks like persistent plumbing — it is not, so it must not
    // be filtered out the way an MCP server is. The ~1s gap between leases is
    // covered by the live-counter scan, not by counting caffeinate as idle.
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "claude"),
        processes: [
            supervisorTestProcess(pid: 100, parentPID: 1, commandName: "/opt/homebrew/bin/claude", arguments: "claude", elapsed: 600),
            supervisorTestProcess(
                pid: 101,
                parentPID: 100,
                commandName: "/usr/bin/caffeinate",
                arguments: "caffeinate -i -t 300",
                elapsed: 140
            )
        ]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .needInput
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test func supervisorReadsFinishedTurnSummaryAsIdle() {
    // Claude replaces the spinner with a past-tense summary carrying the same
    // duration (`✻ Sautéed for 35m 26s · done 10:15 AM`) and drops its sleep
    // assertion. Neither the duration nor the elided cwd may keep it executing.
    let idleText = [
        "✻ Sautéed for 35m 26s · done 10:15 AM",
        "",
        "──────────────────────────────────────────────",
        "❯ ",
        "──────────────────────────────────────────────",
        "  Opus 5 (1M context) | 15% ctx | …/repo | TASK-123"
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: idleText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
    #expect(result?.tone == .yellow)
}

@Test func supervisorDoesNotReadScheduledTaskHeaderAsLiveCounter() {
    // `✻ Running scheduled task (Sep 6 10:02am)` ends in a parenthetical on a line
    // whose verb is in the progress list, but it is a header, not a live counter.
    let idleText = [
        "✻ Running scheduled task (Sep 6 10:02am)",
        "✻ Churned for 6s · done 10:02 AM",
        "❯ "
    ].joined(separator: "\n")

    let result = makeTestSupervisor(visibleText: idleText, processes: [supervisorTestAgentProcess("claude")]).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .executing
    )

    #expect(result?.status == .needInput)
}

@Test func supervisorCanDetectAgentFromPaneRootProcessArguments() {
    let processTable = ProcessTable(rows: [
        supervisorTestProcess(pid: 100, commandName: "/bin/zsh", arguments: "/bin/zsh /tmp/banyan-e2e/codex", elapsed: 5),
        supervisorTestProcess(pid: 101, parentPID: 100, commandName: "/bin/sleep", arguments: "sleep 240", elapsed: 5)
    ])
    let result = makeTestSupervisor(
        pane: supervisorTestPane(rootPID: 100, currentCommand: "zsh"),
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
    let result = makeTestSupervisor(
        visibleText: supervisorFreshClaudePane,
        processes: [supervisorTestAgentProcess("claude")]
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

    let result = makeTestSupervisor(visibleText: freshText, processes: [supervisorTestAgentProcess("codex")]).inspect(
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
    let clearedText = supervisorFreshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: "❯ /clear\n\n─────────────────────────────────────── ↯ ─"
    )

    let result = makeTestSupervisor(
        visibleText: clearedText,
        processes: [supervisorTestAgentProcess("claude")]
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
    let heartbeatText = supervisorFreshClaudePane.replacingOccurrences(
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

    let result = makeTestSupervisor(
        visibleText: heartbeatText,
        processes: [supervisorTestAgentProcess("claude")]
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
    let mixedText = supervisorFreshClaudePane.replacingOccurrences(
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

    let result = makeTestSupervisor(
        visibleText: mixedText,
        processes: [supervisorTestAgentProcess("claude")]
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
    let loopText = supervisorFreshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "✻ Claude resuming /loop wakeup (Aug 11 3:39pm)",
            "",
            "⏺ CI failed on main: 3 tests broken in SessionStore.",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeTestSupervisor(
        visibleText: loopText,
        processes: [supervisorTestAgentProcess("claude")]
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

    let result = makeTestSupervisor(
        visibleText: compactText,
        processes: [supervisorTestAgentProcess("claude")]
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
    ] + [supervisorFreshClaudePane]).joined(separator: "\n")
        .replacingOccurrences(
            of: "─────────────────────────────────────── ↯ ─",
            with: "❯ /clear\n\n─────────────────────────────────────── ↯ ─"
        )

    let result = makeTestSupervisor(
        visibleText: clearedText,
        processes: [supervisorTestAgentProcess("claude")]
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
    let askingText = supervisorFreshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ ship it",
            "",
            "⏺ Do you want me to force-push over the remote branch?",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    let result = makeTestSupervisor(
        visibleText: askingText,
        processes: [supervisorTestAgentProcess("claude")]
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
    let finishedText = supervisorFreshClaudePane.replacingOccurrences(
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

    let result = makeTestSupervisor(
        visibleText: finishedText,
        processes: [supervisorTestAgentProcess("claude")]
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

    let result = makeTestSupervisor(
        visibleText: bannerlessText,
        processes: [supervisorTestAgentProcess("claude")]
    ).inspect(
        tmuxSessionName: "agent",
        launchCommand: "claude",
        currentStatus: .running
    )

    #expect(result?.status == .needInput)
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
    #expect(rows.contains { $0.pid > 1 && $0.parentPID > 0 })
    // The kernel reader exists to escape the 16-character cap `ps -o comm=`
    // applies to an executable path; on a Mac essentially every Homebrew- or
    // nvm-installed binary sits beyond it.
    #expect(rows.contains { $0.commandName.count > 16 && $0.commandName.hasPrefix("/") })
}
