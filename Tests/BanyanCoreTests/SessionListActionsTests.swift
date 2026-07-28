import Foundation
import Testing
@testable import BanyanCore

@Test func sessionActionsSatisfiesTheListCommandProtocol() {
    let actions: any SessionListActions = SessionActions(
        idAllocator: UniqueSessionIDAllocator(
            persistence: EmptyPersistence(),
            tmux: LookupBackend()
        ),
        catalog: SessionCatalog(
            persistence: EmptyPersistence(),
            runtime: SessionRuntimeCoordinator(backend: LifecycleBackend())
        ),
        history: DefaultSessionHistoryBackend()
    )

    #expect(actions is SessionActions)
}

private struct EmptyPersistence: SessionPersistenceBackend {
    func load() -> [SessionSnapshot] { [] }
    func save(_ snapshots: [SessionSnapshot]) {}
}

private struct LookupBackend: TmuxSessionLookupBackend {
    func hasSession(named name: String) -> Bool { false }
}

private struct LifecycleBackend: TmuxSessionLifecycleBackend {
    func hasSession(named name: String) -> Bool { false }
    func ensureSession(named name: String, cwd: String, command: String) throws {}
    func killSession(named name: String) {}
}
