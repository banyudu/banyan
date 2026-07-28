import Testing
@testable import BanyanCore

@Test func lifecycleBackendDoesNotRequirePaneInspection() {
    let backend: any TmuxSessionLifecycleBackend = LifecycleTestBackend()
    #expect(backend.hasSession(named: "banyan-test") == false)
}

private struct LifecycleTestBackend: TmuxSessionLifecycleBackend {
    func hasSession(named name: String) -> Bool { false }
    func ensureSession(named name: String, cwd: String, command: String) throws {}
    func killSession(named name: String) {}
}
