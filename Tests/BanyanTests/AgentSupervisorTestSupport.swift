import Foundation
import BanyanCore
import Testing
@testable import Banyan


let supervisorFreshClaudePane = [
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

let supervisorFreshOpenCodePane = [
    "█▀▀█ █▀▀█ █▀▀█ █▀▀▄ █▀▀▀ █▀▀█ █▀▀█ █▀▀█",
    "█  █ █  █ █▀▀▀ █  █ █    █  █ █  █ █▀▀▀",
    "▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
    "┃",
    "┃  Ask anything... \"Fix a TODO in the codebase\"",
    "┃",
    "┃  Flash-Med · DeepSeek V4 Flash (2x usage) OpenCode Go",
    "╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
    "tab agents  ctrl+p commands",
    "/tmp                                                                                                 1.18.18"
].joined(separator: "\n")

func makeTestSupervisor(
    pane: TmuxPaneSnapshot? = supervisorTestPane(),
    sessionExists: Bool = true,
    visibleText: String = "",
    processes: [ProcessInfoRow] = []
) -> AgentSupervisor {
    AgentSupervisor(
        backend: FakeSupervisorBackend(pane: pane, sessionExists: sessionExists, visibleText: visibleText),
        processTable: ProcessTable(rows: processes)
    )
}

func supervisorTestPane(
    rootPID: Int = 100,
    currentCommand: String = "zsh",
    isDead: Bool = false,
    lastActivityAt: Date? = nil
) -> TmuxPaneSnapshot {
    TmuxPaneSnapshot(
        paneID: "%1",
        rootPID: rootPID,
        currentCommand: currentCommand,
        currentPath: "/tmp",
        isDead: isDead,
        isInMode: false,
        lastActivityAt: lastActivityAt,
        width: 120,
        height: 40
    )
}

/// A live agent process, child of the default pane's login shell (rootPID 100).
/// A running claude/codex/opencode always appears as such a child, so tests that
/// exercise an *active* agent session must include one — the launch command alone
/// no longer implies a live agent.
func supervisorTestAgentProcess(_ provider: String, pid: Int = 101) -> ProcessInfoRow {
    supervisorTestProcess(pid: pid, parentPID: 100, commandName: "/opt/homebrew/bin/\(provider)", arguments: provider, elapsed: 5)
}

func supervisorTestProcess(
    pid: Int = 101,
    parentPID: Int = 100,
    commandName: String,
    arguments: String,
    elapsed: TimeInterval,
    state: String = "S"
) -> ProcessInfoRow {
    ProcessInfoRow(
        pid: pid,
        parentPID: parentPID,
        state: state,
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
