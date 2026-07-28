import BanyanCore
import Foundation

private func makeDefaultApp() -> BanyanTUI {
    let backend = TmuxBackend(
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: NSHomeDirectory()
    )
    let database = SessionDatabase(
        databaseURL: SessionDatabase.defaultDatabaseURL(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
        ),
        legacyJSONURL: SessionDatabase.defaultLegacyJSONURL(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
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
                homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
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
                homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
            )
        ),
        input: TerminalMode(),
        output: output,
        processRunner: InteractiveProcessRunner(),
        renderer: StandardTUIRenderer(),
        currentDirectory: FileManager.default.currentDirectoryPath
    )
}

private var app = makeDefaultApp()
app.run()
