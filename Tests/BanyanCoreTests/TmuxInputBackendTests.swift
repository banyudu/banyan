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

@Test func codexRetryPromptUsesOneTmuxCommandAndHonorsCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-retry-input-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = root.appendingPathComponent("record-tmux")
    let log = root.appendingPathComponent("arguments")
    try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$BANYAN_RETRY_INPUT_LOG\"\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let backend: any TmuxInputBackend = TmuxBackend(executableURL: executable, workingDirectory: root.path,
        environment: ["PATH": "/usr/bin:/bin", "BANYAN_RETRY_INPUT_LOG": log.path], socketName: "retry-fixture")
    let text = "Continue; check completed actions $(literal)"
    try await backend.sendPrompt(paneID: "%3", text: text, isCancelled: { false })
    let actual = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(Array(actual.suffix(11)) == ["send-keys", "-t", "%3", "-l", "--", text, ";", "send-keys", "-t", "%3", "Enter"])
    await #expect(throws: (any Error).self) {
        try await backend.sendPrompt(paneID: "%3", text: "Must not send", isCancelled: { true })
    }
    #expect(try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init) == actual)
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
