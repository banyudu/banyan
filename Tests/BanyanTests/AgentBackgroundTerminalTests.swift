import Foundation
import BanyanCore
import Testing
@testable import Banyan

@Suite struct AgentBackgroundTerminalTests {
    private let footer = "1 background terminal running · /ps to view · /stop to close"
    private let agent = supervisorTestAgentProcess("codex")
    private let server = supervisorTestProcess(pid: 102, parentPID: 101,
        commandName: "node", arguments: "node dev-server.js", elapsed: 3600)

    private func inspect(_ text: String, children: Bool = true) -> AgentSupervisor.Result? {
        makeTestSupervisor(visibleText: text, processes: children ? [agent, server] : [agent])
            .inspect(tmuxSessionName: "test", launchCommand: "codex", currentStatus: .executing)
    }

    @Test func finishedTurnWithDevServerWaitsForInput() throws {
        let screen = "Finished the changes.\nWorked for 2m\n\(footer)\n› Ask Codex to do anything\n? for shortcuts"
        let result = try #require(inspect(screen))
        #expect(result.status == .needInput)
        #expect(result.backgroundTerminalCount == 1)
        #expect(result.visibleText == screen)
        #expect(result.liveProcessIDs.contains(102)) // Exit still wakes the observer.
    }

    @Test func liveTurnStillExecutesWithBackgroundServer() throws {
        let result = try #require(inspect("• Working (2s • esc to interrupt) · \(footer)\n› Ask Codex to do anything"))
        #expect(result.status == .executing)
        #expect(result.backgroundTerminalCount == 1)
    }

    @Test func questionStillNeedsAttentionWithBackgroundServer() throws {
        let result = try #require(inspect("Can I edit these files?\n\(footer)\n› Ask Codex to do anything"))
        #expect(result.status == .asking)
        #expect(result.backgroundTerminalCount == 1)
    }

    @Test func foregroundProcessWithoutReportedBackgroundWorkStaysBusy() throws {
        let result = try #require(inspect("Running a command\n› Ask Codex to do anything"))
        #expect(result.status == .executing)
        #expect(result.backgroundTerminalCount == 0)
    }

    @Test func stoppedServerClearsBadgeEvenBeforeFooterRedraws() throws {
        let result = try #require(inspect("Done\n\(footer)\n› Ask Codex to do anything", children: false))
        #expect(result.status == .needInput)
        #expect(result.backgroundTerminalCount == 0)
    }

    @Test func oldFooterInConversationDoesNotOverrideForegroundProcess() throws {
        let result = try #require(inspect("\(footer)\nA later response\n› Ask Codex to do anything"))
        #expect(result.status == .executing)
        #expect(result.backgroundTerminalCount == 0)
    }

    @Test func footerCountsTerminalsRatherThanWorkerProcesses() throws {
        let screen = "Done\n2 background terminals running · /ps to view\n· /stop to close\n› Ask Codex to do anything"
        let worker = supervisorTestProcess(pid: 103, parentPID: 102, commandName: "node",
            arguments: "node worker.js", elapsed: 3600)
        let result = try #require(makeTestSupervisor(visibleText: screen, processes: [agent, server, worker])
            .inspect(tmuxSessionName: "test", launchCommand: "codex", currentStatus: .executing))
        #expect(result.status == .needInput)
        #expect(result.backgroundTerminalCount == 2)
    }

    @Test func backgroundReportDoesNotMaskActiveTurnAboveQueuedInputs() throws {
        let screen = "• Working (2s • esc to interrupt) · \(footer)\n• Queued follow-up inputs\nFollow up\n› Ask Codex to do anything"
        let result = try #require(inspect(screen))
        #expect(result.status == .executing)
        #expect(result.backgroundTerminalCount == 1)
    }

    @Test func subagentsRetainTheirOwnStatusAndTheBackgroundBadge() throws {
        let childAgent = supervisorTestProcess(pid: 103, parentPID: 101, commandName: "claude",
            arguments: "claude", elapsed: 5)
        let result = try #require(makeTestSupervisor(visibleText: "\(footer)\n› Ask Codex to do anything",
            processes: [agent, server, childAgent])
            .inspect(tmuxSessionName: "test", launchCommand: "codex", currentStatus: .executing))
        #expect(result.status == .subagents)
        #expect(result.backgroundTerminalCount == 1)
    }
}
