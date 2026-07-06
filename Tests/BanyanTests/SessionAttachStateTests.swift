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
private func makeAttachStateSession(isRestored: Bool, status: SessionStatus = .running) -> BanyanSession {
    BanyanSession(
        id: "attach-state",
        title: "/tmp",
        cwd: "/tmp",
        command: "",
        status: status,
        isRestored: isRestored,
        theme: .system
    )
}
