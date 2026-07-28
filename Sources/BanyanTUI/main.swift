import BanyanCore
import Foundation

private func makeDefaultApp() -> BanyanTUI {
    let backend = TmuxBackend.shared
    let database = SessionDatabase()
    return BanyanTUI(
        backend: backend,
        dataSource: SessionDataSource(
            persistence: database,
            backend: backend,
            processTable: LiveProcessTableProvider(),
            historyBackend: DefaultSessionHistoryBackend()
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
            history: DefaultSessionHistoryBackend()
        ),
        input: TerminalMode(),
        output: StandardTUIOutput(),
        currentDirectory: FileManager.default.currentDirectoryPath
    )
}

private var app = makeDefaultApp()
app.run()
