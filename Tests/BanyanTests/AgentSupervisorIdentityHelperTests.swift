import BanyanCore
import Foundation
import Testing

/// Claude keeps Banyan's provider-identity `wait` helper alive under the agent
/// for the whole session. An idle session must not read as executing because of
/// it, while real work and look-alikes from elsewhere still do.
@Suite struct AgentSupervisorIdentityHelperTests {
    private let host = "/Applications/Banyan.app/Contents/MacOS/banyanctl"

    private func bridge(paneRootPID: Int = 100) -> String {
        "/var/folders/xy/T/banyan-provider-\(getuid())-\(paneRootPID)-1794197584-239924"
    }

    private func helper(pid: Int = 102, parentPID: Int = 101, paneRootPID: Int = 100,
                        nonce: String = "", structured: Bool = true) -> ProcessInfoRow {
        let argv = [host, AgentProviderIdentity.helper, "wait", bridge(paneRootPID: paneRootPID), nonce]
        return ProcessInfoRow(pid: pid, parentPID: parentPID, state: "S", elapsed: 120,
            commandName: host, arguments: argv.joined(separator: " "),
            argumentVector: structured ? argv : nil)
    }

    private func inspect(_ processes: [ProcessInfoRow], text: String = "") throws -> AgentSupervisor.Result {
        try #require(makeTestSupervisor(visibleText: text,
            processes: [supervisorTestAgentProcess("claude")] + processes)
            .inspect(tmuxSessionName: "test", launchCommand: "claude", currentStatus: .executing))
    }

    @Test(arguments: [
        (true, ""), (false, ""),
        (true, "6F1C2B3A-4D5E-4F60-8172-93A4B5C6D7E8"), (false, "6F1C2B3A-4D5E-4F60-8172-93A4B5C6D7E8")
    ])
    func dormantWaitHelperDoesNotPinIdleSessionToExecuting(structured: Bool, nonce: String) throws {
        let result = try inspect([helper(nonce: nonce, structured: structured)])
        #expect(result.status == .needInput)
        #expect(result.liveProcessIDs.contains(102))
    }

    @Test func liveTurnStillReadsAsExecutingBesideTheHelper() throws {
        let result = try inspect([helper()], text: "✻ Brewing… (12s · esc to interrupt)\n❯ ")
        #expect(result.status == .executing)
    }

    @Test func realCommandStillReadsAsExecutingBesideTheHelper() throws {
        let command = supervisorTestProcess(pid: 103, parentPID: 101,
            commandName: "/usr/bin/swift", arguments: "swift test", elapsed: 5)
        #expect(try inspect([helper(), command]).status == .executing)
    }

    @Test func helperForAnotherPaneStillCounts() throws {
        #expect(try inspect([helper(paneRootPID: 999)]).status == .executing)
    }

    @Test func helperNotOwnedByTheAgentStillCounts() throws {
        #expect(try inspect([helper(parentPID: 100)]).status == .executing)
    }
}
