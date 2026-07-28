import Foundation
import Testing
@testable import BanyanCore

@Test func sessionCatalogCoordinatesCreateAndClose() throws {
    let persistence = FakeCatalogPersistence()
    let backend = FakeCatalogBackend()
    let catalog = SessionCatalog(
        persistence: persistence,
        runtime: SessionRuntimeCoordinator(backend: backend)
    )
    let now = Date(timeIntervalSince1970: 100)
    let snapshot = SessionSnapshot(
        id: "catalog-session",
        tmuxSessionName: "banyan-catalog",
        title: "Shell",
        reportedTitle: nil,
        cwd: "/tmp",
        command: "",
        status: .running,
        tone: .blue,
        createdAt: now,
        updatedAt: now
    )
    try catalog.create(snapshot: snapshot)
    #expect(persistence.snapshots == [snapshot])
    #expect(backend.events == ["ensure:banyan-catalog"])

    catalog.close(snapshot: snapshot)
    #expect(persistence.snapshots.first?.status == .closed)
    #expect(backend.events == ["ensure:banyan-catalog", "kill:banyan-catalog"])
}

private final class FakeCatalogPersistence: SessionPersistenceBackend, @unchecked Sendable {
    var snapshots: [SessionSnapshot] = []

    func load() -> [SessionSnapshot] { snapshots }
    func save(_ snapshots: [SessionSnapshot]) { self.snapshots = snapshots }
}

private final class FakeCatalogBackend: TmuxSessionLifecycleBackend, @unchecked Sendable {
    var events: [String] = []

    func hasSession(named name: String) -> Bool { false }
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }

    func ensureSession(named name: String, cwd: String, command: String) throws {
        events.append("ensure:\(name)")
    }

    func killSession(named name: String) {
        events.append("kill:\(name)")
    }
}
