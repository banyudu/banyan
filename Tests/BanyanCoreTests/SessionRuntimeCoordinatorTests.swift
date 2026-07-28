import Testing
@testable import BanyanCore

@Test func runtimeCoordinatorDelegatesRestartInOrder() throws {
    let backend = FakeLifecycleBackend()
    let coordinator = SessionRuntimeCoordinator(backend: backend)
    let request = SessionLaunchRequest(sessionName: "banyan-test", cwd: "/tmp", command: "codex")

    try coordinator.restartBackingSession(request)

    #expect(backend.events == [
        "kill:banyan-test",
        "ensure:banyan-test:/tmp:codex"
    ])
}

private final class FakeLifecycleBackend: TmuxSessionLifecycleBackend, @unchecked Sendable {
    var events: [String] = []

    func hasSession(named name: String) -> Bool { false }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }

    func ensureSession(named name: String, cwd: String, command: String) throws {
        events.append("ensure:\(name):\(cwd):\(command)")
    }

    func killSession(named name: String) {
        events.append("kill:\(name)")
    }
}
