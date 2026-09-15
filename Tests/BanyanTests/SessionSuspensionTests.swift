import Foundation
import BanyanCore
import Testing
@testable import Banyan

@MainActor
@Test func suspendingASessionLeavesItsTmuxSessionRunning() throws {
    let backing = try TmuxBackedSession(idPrefix: "suspend-keeps-tmux")
    defer { backing.tearDown() }
    let session = backing.session
    session.isProcessStarted = true

    session.suspend()

    #expect(session.isSuspended)
    // The whole point of a soft suspend: only Banyan stops paying for the
    // session. Nothing behind it is torn down.
    #expect(backing.tmux.hasSession(named: backing.tmuxSessionName))
    #expect(backing.tmux.listBanyanSessions().contains(backing.tmuxSessionName))
}

@MainActor
@Test func suspendedSessionsDropOutOfTheSupervisorTick() throws {
    let backing = try TmuxBackedSession(idPrefix: "suspend-drops-tick", status: .executing)
    defer { backing.tearDown() }
    let session = backing.session
    session.isProcessStarted = true

    #expect(SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: session.isProcessStarted,
        isRestored: session.isRestored,
        isSuspended: session.isSuspended
    ))

    session.suspend()

    #expect(!SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: session.isProcessStarted,
        isRestored: session.isRestored,
        isSuspended: session.isSuspended
    ))
}

@MainActor
@Test func resumingKeepsTheLastObservedStatusAndReusesTheSameTmuxSession() throws {
    let backing = try TmuxBackedSession(idPrefix: "resume-keeps-status", status: .executing)
    defer { backing.tearDown() }
    let session = backing.session
    session.isProcessStarted = true
    session.tone = .yellow

    session.suspend()
    // Parking must not reset the agent's state — resume is supposed to give it
    // back, not start over from `.running`.
    #expect(session.status == .executing)
    #expect(session.tone == .yellow)

    session.resume()

    #expect(!session.isSuspended)
    #expect(session.status == .executing)
    #expect(session.tone == .yellow)
    #expect(!session.needsRecovery)
    // Re-entering the tick must not wait for a visible client to attach.
    #expect(session.isProcessStarted)
    #expect(SessionLifecyclePolicy.participatesInSupervisorTick(
        isProcessStarted: session.isProcessStarted,
        isRestored: session.isRestored,
        isSuspended: session.isSuspended
    ))
    #expect(backing.tmux.hasSession(named: backing.tmuxSessionName))
}

@MainActor
@Test func resumingASessionWhoseTmuxSessionDiedWhileParkedAsksForRecovery() throws {
    let backing = try TmuxBackedSession(idPrefix: "resume-detects-death")
    defer { backing.tearDown() }
    let session = backing.session
    session.isProcessStarted = true

    session.suspend()
    // Nothing observes a parked session, so this death goes unnoticed until the
    // probe in `resume()` (or the hourly liveness sweep) looks.
    backing.tmux.killSession(named: backing.tmuxSessionName)

    session.resume()

    #expect(!session.isSuspended)
    #expect(session.needsRecovery)
    #expect(!session.isProcessStarted)
    #expect(session.needsManualAttach)
}

@MainActor
@Test func closingAParkedSessionStopsItBeingParked() throws {
    let backing = try TmuxBackedSession(idPrefix: "close-unparks")
    defer { backing.tearDown() }
    let session = backing.session
    session.isProcessStarted = true

    session.suspend()
    session.killBackingSession()

    // A closed row is over, not parked: the flag must not survive into history
    // or into a later reopen.
    #expect(session.status == .closed)
    #expect(!session.isSuspended)
    #expect(!backing.tmux.hasSession(named: backing.tmuxSessionName))
}

@MainActor
@Test func aParkedSessionRefusesToStartATerminalClient() throws {
    let backing = try TmuxBackedSession(idPrefix: "parked-refuses-start")
    defer { backing.tearDown() }
    let session = backing.session

    session.suspend()
    session.startBackgroundBackendIfNeeded()

    // Anything that would put the session back on Banyan's budget has to go
    // through `resume()`, so nothing can quietly unpark it.
    #expect(session.isSuspended)
    #expect(!session.isProcessStarted)
}

/// A `BanyanSession` with a real `tmux -L banyan` session behind it, so tests can
/// assert on what suspension does and does not touch.
@MainActor
private struct TmuxBackedSession {
    let tmux: TmuxBackend
    let tmuxSessionName: String
    let session: BanyanSession

    init(idPrefix: String, status: SessionStatus = .running) throws {
        tmux = banyanTestTmuxBackend
        let id = "\(idPrefix)-\(UUID().uuidString.lowercased())"
        tmuxSessionName = TmuxBackend.sessionName(for: id)
        try tmux.ensureSession(named: tmuxSessionName, cwd: "/tmp", command: "")
        session = BanyanSession(
            id: id,
            tmuxSessionName: tmuxSessionName,
            title: "Parked",
            cwd: "/tmp",
            command: "",
            status: status,
            isRestored: true,
            theme: .system,
            tmuxBackend: banyanTestTmuxBackend,
            telemetry: banyanTestTelemetry,
            host: banyanTestHost
        )
    }

    func tearDown() {
        tmux.killSession(named: tmuxSessionName)
    }
}
