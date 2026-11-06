import Testing
@testable import BanyanCore

@Suite struct AgentSupervisorQuestionTests {
    private func inspect(_ text: String) throws -> AgentSupervisor.Result {
        let supervisor = AgentSupervisor(backend: QuestionBackend(text: text),
            processTable: ProcessTable(rows: [
                ProcessInfoRow(pid: 101, parentPID: 100, state: "S", elapsed: 600,
                    commandName: "codex", arguments: "codex")
            ]))
        return try #require(supervisor.inspect(tmuxSessionName: "test",
            launchCommand: "codex", currentStatus: .asking))
    }

    private func finishedScreen(_ lines: [String]) -> String {
        (lines + ["Worked for 7m 26s", "› Ask Codex to do anything", "? for shortcuts"]).joined(separator: "\n")
    }

    @Test func completedTurnDoesNotAskBecauseUserPreviouslyApproved() throws {
        let text = finishedScreen(["• Can I start the worker?", "› approved",
            "• Started a worker. The handoff includes the fix.", "spawned 1 issue(s)"])
        let result = try inspect(text)
        #expect(result.status == .needInput)
        #expect(result.visibleText == text)
    }

    @Test func historicalQuestionDoesNotOutrankFinishedOutput() throws {
        let text = finishedScreen(["• Do you want me to continue?"]
            + Array(repeating: "• Ran a command successfully.", count: 20)
            + ["• Finished the changes."])
        #expect(try inspect(text).status == .needInput)
    }

    @Test(arguments: ["› Can I run this?", "❯ Please approve this", "❱ Would you like a fix?"])
    func echoedUserQuestionIsNotAnAgentQuestion(prompt: String) throws {
        #expect(try inspect(finishedScreen([prompt, "• Finished the requested changes."])).status == .needInput)
    }

    @Test(arguments: ["• The change was approved.", "• The app can initialize successfully."])
    func questionPhrasesMustMatchWholeWords(summary: String) throws {
        #expect(try inspect(finishedScreen([summary])).status == .needInput)
    }

    @Test(arguments: ["Can I edit these files?", "Should I retry?", "Please approve this action.", "Approval required"])
    func currentQuestionStillAsks(question: String) throws {
        #expect(try inspect(finishedScreen(["› approved", "• " + question])).status == .asking)
    }

    @Test(arguments: ["›", "❯"])
    func permissionDialogStillAsks(cursor: String) throws {
        let text = "Would you like to run this command?\n\(cursor) 1. Yes\n  2. No\nPress enter to confirm"
        #expect(try inspect(text).status == .asking)
    }

    @Test func composerFooterAndQueuedInputAreNotQuestions() throws {
        let text = """
        • Finished the changes.
        • Queued follow-up inputs
          Can I retry this?
        › Ask Codex to do anything
        ~/dev/should i approve this
        ? for shortcuts
        """
        #expect(try inspect(text).status == .needInput)
    }
}

private struct QuestionBackend: AgentSupervisorBackend {
    let text: String
    func hasSession(named name: String) -> Bool { true }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? {
        .init(paneID: "%1", rootPID: 100, currentCommand: "codex", currentPath: "/tmp",
            isDead: false, isInMode: false)
    }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { text }
}
