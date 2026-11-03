@testable import Banyan
import BanyanCore
import Testing

@Test func terminalSlashCommandsParseTheirCanonicalNamesAndAliases() {
    for command in TerminalSlashCommand.allCases {
        #expect(TerminalSlashCommand.parse(command.rawValue) == command)
        #expect(TerminalSlashCommand.parse("  \(command.rawValue.uppercased())\n") == command)
        for alias in command.aliases {
            #expect(TerminalSlashCommand.parse(alias) == command)
        }
    }
}

@Test func terminalSlashCommandsHaveUniqueInvocations() {
    let invocations = TerminalSlashCommand.allCases.flatMap { [$0.rawValue] + $0.aliases }
    #expect(Set(invocations).count == invocations.count)
    #expect(invocations.allSatisfy { $0.hasPrefix("/") && $0.count > 1 })
}

@Test func terminalSlashCommandParsingLeavesAgentCommandsAlone() {
    for input in ["/clear", "/compact", "/review", "/status", "/model", "/init"] {
        #expect(TerminalSlashCommand.parse(input) == nil)
    }
}

@Test func terminalSlashCommandParsingRequiresTheWholeSubmittedLine() {
    #expect(TerminalSlashCommand.parse("/new fix the tests") == nil)
    #expect(TerminalSlashCommand.parse("run /new") == nil)
    #expect(TerminalSlashCommand.parse("/newer") == nil)
    #expect(TerminalSlashCommand.parse("") == nil)
}

@Test func terminalSlashCommandPolicyRequiresALiveCodingAgent() {
    #expect(TerminalSlashCommandPolicy.canHandle(
        provider: .codex, isImportedHistory: false, status: .idle
    ))
    #expect(TerminalSlashCommandPolicy.canHandle(
        provider: .claude, isImportedHistory: false, status: .executing
    ))

    #expect(!TerminalSlashCommandPolicy.canHandle(
        provider: nil, isImportedHistory: false, status: .idle
    ))
    #expect(!TerminalSlashCommandPolicy.canHandle(
        provider: .codex, isImportedHistory: true, status: .idle
    ))
    #expect(!TerminalSlashCommandPolicy.canHandle(
        provider: .codex, isImportedHistory: false, status: .closed
    ))
}
