import BanyanCore
import Foundation

private func makeDefaultApp(host: HostRuntimeContext) throws -> BanyanTUI {
    let backend = TmuxBackend(
        environment: host.environment,
        workingDirectory: host.homeDirectory.path,
        socketName: fixtureSocket(environment: host.environment) ?? TmuxBackend.socketName
    )
    let database = SessionDatabase(
        databaseURL: SessionDatabase.defaultDatabaseURL(
            environment: host.environment,
            homeDirectory: host.homeDirectory
        ),
        legacyJSONURL: SessionDatabase.defaultLegacyJSONURL(
            environment: host.environment,
            homeDirectory: host.homeDirectory
        )
    )
    let output = StandardTUIOutput()
    return BanyanTUI(
        backend: backend,
        dataSource: SessionDataSource(
            persistence: database,
            backend: backend,
            processTable: LiveProcessTableProvider(),
            historyBackend: DefaultSessionHistoryBackend(
                homeDirectory: host.homeDirectory
            )
        ),
        actions: SessionActions(
            idAllocator: UniqueSessionIDAllocator(
                persistence: database,
                tmux: backend
            ),
            catalog: SessionCatalog(
                persistence: database,
                runtime: SessionRuntimeCoordinator(backend: backend)
            ),
            history: DefaultSessionHistoryBackend(
                homeDirectory: host.homeDirectory
            )
        ),
        input: TerminalMode(),
        output: output,
        processRunner: InteractiveProcessRunner(),
        puckClient: PuckDaemonClient(environment: host.environment,
                                     homeDirectory: host.homeDirectory.path),
        currentDirectory: host.currentDirectory,
        events: try TUIEvents(watchSignals: true),
        environment: host.environment
    )
}

// Runtime smoke fixtures must opt into BOTH a private data home and a private
// socket. Never allow a fixture database to enumerate the live Banyan server.
private func fixtureSocket(environment: [String: String]) -> String? {
    guard BanyanDataDirectory.fixtureDataHome(environment: environment) != nil else { return nil }
    guard let socket = environment["BANYAN_FIXTURE_TMUX_SOCKET"], socket.hasPrefix("banyan-tui-fixture-") else {
        return "banyan-tui-fixture-\(UUID().uuidString.lowercased())"
    }
    return socket
}

private let environment = ProcessInfo.processInfo.environment
private let host = HostRuntimeContext(
    environment: environment,
    homeDirectory: BanyanDataDirectory.fixtureDataHome(environment: environment)
        ?? URL(fileURLWithPath: NSHomeDirectory()),
    currentDirectory: FileManager.default.currentDirectoryPath
)

do {
    var app = try makeDefaultApp(host: host)
    app.run()
} catch {
    FileHandle.standardError.write(Data("BanyanTUI: \(error.localizedDescription)\n".utf8))
    exit(1)
}
