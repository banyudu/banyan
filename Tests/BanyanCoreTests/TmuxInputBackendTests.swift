import Foundation
import Testing
@testable import BanyanCore

@Test func inputBackendSendsNothingForAnEmptyRequest() throws {
    // An answer that resolved to no keystrokes must not reach tmux at all — a bare
    // `send-keys -t %1` with no arguments is a command, not a no-op.
    let backend = RecordingInputBackend()

    try backend.sendKeys(paneID: "%1", keys: [])
    try backend.sendLiteral(paneID: "%1", text: "")

    #expect(backend.sent.isEmpty)
}

@Test func inputBackendRecordsKeysAndLiteralsSeparately() throws {
    let backend = RecordingInputBackend()

    try backend.sendLiteral(paneID: "%1", text: "Enter")
    try backend.sendKeys(paneID: "%1", keys: [.down, .enter])

    #expect(backend.sent == [
        ["send-keys", "-t", "%1", "-l", "--", "Enter"],
        ["send-keys", "-t", "%1", "Down", "Enter"]
    ])
}

@Test func inputBackendPropagatesAFailureRatherThanReportingSuccess() {
    // A caller that has told a human "sent" must not learn afterwards that tmux
    // refused, so the failure has to surface rather than be swallowed.
    let backend = RecordingInputBackend(failure: TmuxBackend.BackendError.tmuxNotFound)

    #expect(throws: TmuxBackend.BackendError.self) {
        try backend.sendKeys(paneID: "%1", keys: [.enter])
    }
}

@Test func tmuxBackendIsTheSessionStoreSurfaceIncludingInput() {
    // The store's backend has to be able to type into a pane; #62/#63 want the
    // same primitive for respawn, which is why it is a protocol and not a method
    // on one concrete type.
    let backend: any TmuxSessionStoreBackend = TmuxBackend(
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: FileManager.default.currentDirectoryPath
    )
    let input: any TmuxInputBackend = backend

    #expect(input is TmuxBackend)
}

/// Mirrors `TmuxBackend`'s own guard clauses so the fake and the real backend
/// agree about what reaches tmux.
private final class RecordingInputBackend: TmuxInputBackend, @unchecked Sendable {
    private(set) var sent: [[String]] = []
    private let failure: Error?

    init(failure: Error? = nil) {
        self.failure = failure
    }

    func sendKeys(paneID: String, keys: [TmuxKey]) throws {
        guard !keys.isEmpty else { return }
        if let failure { throw failure }
        sent.append(AgentInputCommand.sendKeysArguments(paneID: paneID, keys: keys))
    }

    func sendLiteral(paneID: String, text: String) throws {
        guard !text.isEmpty else { return }
        if let failure { throw failure }
        sent.append(AgentInputCommand.sendLiteralArguments(paneID: paneID, text: text))
    }
}
