import Testing
@testable import Banyan

@MainActor
@Test func normalInactiveDetachDoesNotRequireManualAttach() {
    let session = makeAttachStateSession(isRestored: false)

    session.detachTerminalClient()

    #expect(!session.isProcessStarted)
    #expect(!session.isRestored)
    #expect(!session.needsManualAttach)
}

@MainActor
@Test func restoredRunningSessionDoesNotRequireManualAttachBeforeSelection() {
    let session = makeAttachStateSession(isRestored: true)

    #expect(!session.needsManualAttach)
}

@MainActor
@Test func failedAttachRequiresManualAttach() {
    let session = makeAttachStateSession(isRestored: true, status: .failed)

    #expect(session.needsManualAttach)
}

@MainActor
@Test func submittedInputPromotesIdleAgentSessionToExecuting() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "codex")

    session.noteUserSubmittedInput()

    #expect(session.status == .executing)
    #expect(session.tone == .blue)
}

@MainActor
@Test func submittedInputDoesNotPromotePlainShellSession() {
    let session = makeAttachStateSession(isRestored: false, status: .longRunningShell, command: "")

    session.noteUserSubmittedInput()

    #expect(session.status == .longRunningShell)
}

@MainActor
private func makeAttachStateSession(
    isRestored: Bool,
    status: SessionStatus = .running,
    command: String = ""
) -> BanyanSession {
    BanyanSession(
        id: "attach-state",
        title: "/tmp",
        cwd: "/tmp",
        command: command,
        status: status,
        isRestored: isRestored,
        theme: .system
    )
}
