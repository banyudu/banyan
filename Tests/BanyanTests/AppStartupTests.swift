import AppKit
import BanyanCore
import Foundation
import Testing
@testable import Banyan

@Suite(.serialized)
@MainActor
struct AppStartupTests {
    @Test func windowlessLifecycleRestoresSessionsBeforeServingRequests() async throws {
        let fixture = try StartupFixture()
        fixture.persistence.save([SessionSnapshot(
            id: "restored", tmuxSessionName: nil, title: "Restored session",
            reportedTitle: nil, cwd: fixture.home.path, command: "",
            status: .running, tone: .blue, isSuspended: true,
            createdAt: Date(), updatedAt: Date()
        )])
        let store = fixture.makeStore()
        defer { fixture.stop(store) }
        let existingWindows = NSApp.windows
        let delegate = AppDelegate(startRuntime: store.startRuntimeIfNeeded)

        // No ContentView, hosting controller, or window is created. Use the
        // same native launch callback as the application, before restoration.
        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))

        #expect(NSApp.windows == existingWindows)
        #expect(fixture.sessionsAtServerCreation == [["restored"]])
        #expect(store.sessions.map(\.id) == ["restored"])
        #expect(store.selectedSessionID == "restored")
        let response = try await fixture.listSessions()
        #expect(response.map { $0["id"] as? String } == ["restored"])
        try await waitForPuckState { fixture.daemon.watchCount == 1 }

        delegate.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        store.startControlServer()
        store.startSupervisor()
        #expect(fixture.sessionsAtServerCreation.count == 1)
        #expect(fixture.daemon.watchCount == 1)
        #expect(try await fixture.listSessions().count == 1)
    }

    @Test func windowlessFirstLaunchCreatesOneDefaultAndDoesNotRepeatStartup() async throws {
        let fixture = try StartupFixture()
        let store = fixture.makeStore()
        defer { fixture.stop(store) }
        let delegate = AppDelegate(startRuntime: store.startRuntimeIfNeeded)
        let launch = Notification(name: NSApplication.willFinishLaunchingNotification)

        delegate.applicationWillFinishLaunching(launch)

        let session = try #require(store.sessions.first)
        #expect(store.sessions.count == 1)
        #expect(session.cwd == fixture.home.path)
        #expect(fixture.sessionsAtServerCreation == [[session.id]])
        #expect(try await fixture.listSessions().count == 1)
        try await waitForPuckState { fixture.daemon.watchCount == 1 }

        // A later lifecycle notification must not recreate a default after
        // the user has removed all sessions, or install another listener/watch.
        try store.remove(id: session.id)
        delegate.applicationWillFinishLaunching(launch)

        #expect(store.sessions.isEmpty)
        #expect(fixture.sessionsAtServerCreation.count == 1)
        #expect(fixture.daemon.watchCount == 1)
        #expect(try await fixture.listSessions().isEmpty)
    }
}

@MainActor
private final class StartupFixture {
    let home: URL
    let persistence: SessionPersistence
    let daemon = FakePuckDaemon()
    private let host: HostRuntimeContext
    private let tmux: TmuxBackend
    private var server: ControlServer?
    private(set) var sessionsAtServerCreation: [[String]] = []

    init() throws {
        _ = NSApplication.shared
        home = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        persistence = SessionPersistence(
            databaseURL: home.appendingPathComponent("state.sqlite"),
            legacyJSONURL: home.appendingPathComponent("sessions.json")
        )
        host = HostRuntimeContext(
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh"],
            homeDirectory: home, currentDirectory: home.path
        )
        // Launch restoration reaps stale sessions. Never share the live app's
        // socket, or even the socket used by other concurrently running tests.
        tmux = TmuxBackend(environment: host.environment, workingDirectory: home.path,
                           socketName: "banyan-startup-test-\(UUID().uuidString)")
    }

    func makeStore() -> SessionStore {
        SessionStore(
            persistence: persistence, tmuxBackend: tmux, sessionBackend: tmux,
            processTable: StartupProcessTable(),
            historyBackend: DefaultSessionHistoryBackend(homeDirectory: home),
            detector: AgentStateDetector(rules: []), host: host,
            telemetry: banyanTestTelemetry, attentionNotifier: AttentionNotifier(),
            puckDaemon: daemon,
            makeControlServer: { [unowned self] store, host in
                sessionsAtServerCreation.append(store.sessions.map(\.id))
                let server = ControlServer(store: store, host: host, port: .any)
                self.server = server
                return server
            }
        )
    }

    func listSessions() async throws -> [[String: Any]] {
        let server = try #require(server)
        try await waitForPuckState { server.listeningPort != nil }
        let port = try #require(server.listeningPort)
        let token = try ControlToken.loadOrCreate(environment: host.environment, homeDirectory: home)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/list")!)
        request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(json["data"] as? [String: Any])
        return try #require(payload["sessions"] as? [[String: Any]])
    }

    func stop(_ store: SessionStore) {
        server?.stop()
        store.stopPuckObservation()
        store.flushPendingSessionSaves()
    }
}

private struct StartupProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable { ProcessTable(rows: []) }
}
