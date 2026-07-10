import Foundation
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
@Test func killBackingSessionKillsUnderlyingTmuxSession() throws {
    let tmux = TmuxBackend.shared
    let id = "close-kills-\(UUID().uuidString.lowercased())"
    let tmuxSessionName = TmuxBackend.sessionName(for: id)
    try tmux.ensureSession(named: tmuxSessionName, cwd: "/tmp", command: "")
    defer {
        tmux.killSession(named: tmuxSessionName)
    }

    let session = BanyanSession(
        id: id,
        tmuxSessionName: tmuxSessionName,
        title: "Close kills",
        cwd: "/tmp",
        command: "",
        isRestored: true,
        theme: .system
    )

    #expect(tmux.hasSession(named: tmuxSessionName))

    session.killBackingSession()

    #expect(session.status == .closed)
    #expect(!tmux.hasSession(named: tmuxSessionName))
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
