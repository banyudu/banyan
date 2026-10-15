import Foundation
import Testing
@testable import BanyanCore

@Test(arguments: [SessionStatus.asking, .needInput])
func supervisorRecognizesCodexWorkingAboveQueuedQuestion(previousStatus: SessionStatus) {
    let text = """
    Should I wait for the provider to recover?
    • Working (16m 34s • esc to interrupt)
    • Queued follow-up inputs
      ? 1 question
        ⇧← to answer
    \("   ")
    › Ask Codex to do anything
    \("   ")
    GPT-6.1-Sol xhigh · ~/dev/my-project · Context 41% used
      ? for shortcuts
    """
    let result = codexActivitySupervisor(text).inspect(
        tmuxSessionName: "agent", launchCommand: "codex", currentStatus: previousStatus
    )

    #expect(result?.status == .executing)
    #expect(result?.tone == .blue)
}

@Test(arguments: ["• Queued follow-up inputs", "• Messages to be submitted after next tool call (press esc to interrupt and send immediately)"])
func supervisorRecognizesCodexWorkingAboveLongQueuedInput(queueHeading: String) {
    let text = ([
        "• Working (2m 10s • esc to interrupt)", queueHeading
    ] + Array(repeating: "  ↳ Queued follow-up message", count: 20) + [
        "› Ask Codex to do anything", "GPT-6.1-Sol xhigh", "? for shortcuts"
    ]).joined(separator: "\n")
    let result = codexActivitySupervisor(text).inspect(
        tmuxSessionName: "agent", launchCommand: "codex", currentStatus: .needInput
    )

    #expect(result?.status == .executing)
}

@Test func supervisorIgnoresWhitespacePaddingBelowCodexActivity() {
    let text = (["• Working (12s • esc to interrupt)"] + Array(repeating: "   ", count: 20) + [
        "› Ask Codex to do anything", "GPT-6.1-Sol xhigh", "? for shortcuts"
    ]).joined(separator: "\n")
    #expect(AgentSupervisor.looksLikeAgentExecuting(text))
}

@Test func supervisorDoesNotTreatQueuedMessageInterruptInstructionsAsActivity() {
    let text = """
    Finished the changes.
    • Messages to be submitted after next tool call (press esc to interrupt and send immediately)
      ↳ Review the changes.
    › Ask Codex to do anything
    GPT-6.1-Sol xhigh
    ? for shortcuts
    """
    #expect(!AgentSupervisor.looksLikeAgentExecuting(text))
}

@Test(arguments: [false, true])
func supervisorRecognizesCodexCompletionAfterQueuedQuestion(asking: Bool) {
    let text = """
    \(asking ? "Should I wait for the provider to recover?" : "Finished the changes.")
    › Ask Codex to do anything
    GPT-6.1-Sol xhigh
    ? for shortcuts
    """
    let result = codexActivitySupervisor(text).inspect(
        tmuxSessionName: "agent", launchCommand: "codex", currentStatus: .executing
    )

    #expect(result?.status == (asking ? .asking : .needInput))
    #expect(result?.tone == .yellow)
}

@Test func supervisorKeepsHistoricalInterruptHintOutsideActivityTail() {
    let text = (["• Working (12s • esc to interrupt)"] + Array(repeating: "Finished output", count: 20) + [
        "› Ask Codex to do anything", "GPT-6.1-Sol xhigh", "? for shortcuts"
    ]).joined(separator: "\n")
    #expect(!AgentSupervisor.looksLikeAgentExecuting(text))
}

private func codexActivitySupervisor(_ text: String) -> AgentSupervisor {
    AgentSupervisor(
        backend: CodexActivityBackend(text: text),
        processTable: ProcessTable(rows: [
            ProcessInfoRow(pid: 101, parentPID: 100, state: "S", elapsed: 5,
                           commandName: "codex", arguments: "codex")
        ])
    )
}

private struct CodexActivityBackend: AgentSupervisorBackend {
    let text: String

    func hasSession(named name: String) -> Bool { true }

    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp",
              isDead: false, isInMode: false)
    }

    func captureVisibleText(paneID: String, lineLimit: Int) -> String { text }
}
