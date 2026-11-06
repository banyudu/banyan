import BanyanCore
import Testing

@Suite struct AgentSupervisorRuntimeHelperTests {
    private let finishedTurn = "Finished the changes.\nWorked for 19m\n› Ask Codex to do anything\n? for shortcuts"
    private let runtime = supervisorTestProcess(pid: 102, parentPID: 101,
        commandName: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
        arguments: "node_repl", elapsed: 600)
    private let codexPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

    private func inspect(_ processes: [ProcessInfoRow], text: String? = nil) throws -> AgentSupervisor.Result {
        try #require(makeTestSupervisor(visibleText: text ?? finishedTurn,
            processes: [supervisorTestAgentProcess("codex"), runtime] + processes)
            .inspect(tmuxSessionName: "test", launchCommand: "codex", currentStatus: .subagents))
    }

    @Test(arguments: [false, true])
    func computerUseAppServerDoesNotCountAsSubagent(structuredArguments: Bool) throws {
        let argv = [codexPath, "app-server", "--listen", "stdio://"]
        let server = ProcessInfoRow(pid: 103, parentPID: 102, state: "S", elapsed: 600,
            commandName: codexPath, arguments: argv.joined(separator: " "),
            argumentVector: structuredArguments ? argv : nil)
        let worker = supervisorTestProcess(pid: 104, parentPID: 103,
            commandName: "node", arguments: "node worker.js", elapsed: 599)

        let result = try inspect([server, worker])
        #expect(result.status == .needInput)
        #expect(result.tone == .yellow)
        #expect(result.visibleText == finishedTurn)
        #expect(result.liveProcessIDs.contains(103))
        #expect(result.liveProcessIDs.contains(104))

        let active = try inspect([server, worker], text: "• Working (2s • esc to interrupt)\n› Ask Codex to do anything")
        #expect(active.status == .executing)
    }

    @Test(arguments: ["codex", "codex exec review", "codex exec 'explain app-server'"])
    func realAgentLaunchedByComputerUseStillCounts(arguments: String) throws {
        let child = supervisorTestProcess(pid: 103, parentPID: 102,
            commandName: codexPath, arguments: arguments, elapsed: 5)
        #expect(try inspect([child]).status == .subagents)
    }

    @Test func foregroundCommandLaunchedByComputerUseStillCounts() throws {
        let command = supervisorTestProcess(pid: 103, parentPID: 102,
            commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 5)
        #expect(try inspect([command]).status == .executing)
    }

    @Test func appServerOutsideRuntimeHelperIsNotSilenced() throws {
        let server = supervisorTestProcess(pid: 103, parentPID: 101,
            commandName: codexPath, arguments: "codex app-server", elapsed: 5)
        #expect(try inspect([server]).status == .subagents)
    }

    @Test func agentNamedMCPServerDoesNotCountAsSubagent() throws {
        let server = supervisorTestProcess(pid: 103, parentPID: 101,
            commandName: codexPath, arguments: "codex mcp-server", elapsed: 600)
        #expect(try inspect([server]).status == .needInput)
    }

    @Test func childAgentPromptMentioningMCPStillCounts() throws {
        let child = supervisorTestProcess(pid: 103, parentPID: 101,
            commandName: codexPath, arguments: "codex exec 'review mcp-server setup'", elapsed: 5)
        #expect(try inspect([child]).status == .subagents)
    }
}
