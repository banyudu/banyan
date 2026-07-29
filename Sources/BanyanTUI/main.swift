import BanyanCore
import Foundation

private func makeDefaultApp(host: HostRuntimeContext) -> BanyanTUI {
    let backend = TmuxBackend(
        environment: host.environment,
        workingDirectory: host.homeDirectory.path
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
        renderer: StandardTUIRenderer(),
        currentDirectory: host.currentDirectory
    )
}

private let host = HostRuntimeContext(
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: URL(fileURLWithPath: NSHomeDirectory()),
    currentDirectory: FileManager.default.currentDirectoryPath
)

private var app = makeDefaultApp(host: host)
app.run()
