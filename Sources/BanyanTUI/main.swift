import BanyanCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct BanyanTUI {
    private let tmux = TmuxBackend.shared
    private let attachment = TUIAttachment(tmux: TmuxBackend.shared)
    private let dataSource: TUISessionDataSource
    private let actions: TUISessionActions
    private var sessions: [SessionSnapshot] = []
    private var history: [ImportedAgentSession] = []
    private var viewState = TUIViewState()

    init() {
        let database = SessionDatabase()
        self.dataSource = TUISessionDataSource(database: database, tmux: TmuxBackend.shared)
        self.actions = TUISessionActions(
            database: database,
            tmux: TmuxBackend.shared,
            catalog: SessionCatalog(
                persistence: database,
                runtime: SessionRuntimeCoordinator()
            )
        )
    }

    mutating func run() {
        let terminal = TerminalMode()
        while true {
            reload()
            render()

            guard let byte = readByte() else { break }
            guard handle(TUIAction(byte: byte), terminal: terminal) else { return }
        }
    }

    private mutating func handle(_ action: TUIAction, terminal: TerminalMode) -> Bool {
        switch action {
            case .quit:
                return false
            case .toggleHistory:
                viewState.toggleHistory()
            case .next:
                viewState.moveNext(rowCount: visibleRowCount)
            case .previous:
                viewState.movePrevious()
            case .refresh:
                viewState.refresh()
            case .recover:
                if !viewState.showingHistory { recoverSelected() }
            case .newSession:
                if !viewState.showingHistory { createShellSession() }
            case .close:
                if !viewState.showingHistory { closeSelected() }
            case .remove:
                if !viewState.showingHistory { removeSelected() }
            case .activate:
                terminal.restore()
                if viewState.showingHistory {
                    resumeHistorySelected()
                } else {
                    attachSelected()
                }
                terminal.enterRaw()
            case .trimResume:
                if viewState.showingHistory { resumeHistorySelected(trimmed: true) }
            case .unknown:
                break
        }
        return true
    }

    private mutating func reload() {
        if viewState.showingHistory {
            if viewState.historyNeedsReload {
                history = dataSource.loadHistory()
                viewState.markHistoryLoaded()
            }
            viewState.clampSelection(rowCount: history.count)
            return
        }
        sessions = dataSource.loadActiveSessions()
        viewState.clampSelection(rowCount: sessions.count)
    }

    private var visibleRowCount: Int {
        viewState.showingHistory ? history.count : sessions.count
    }

    private func render() {
        let output = TerminalRenderer.render(
            sessions: sessions,
            history: history,
            showingHistory: viewState.showingHistory,
            selectedIndex: viewState.selectedIndex,
            notice: viewState.notice,
            tmux: tmux
        )
        print(output, terminator: "")
        fflush(stdout)
    }

    private func attachSelected() {
        guard sessions.indices.contains(viewState.selectedIndex) else { return }
        let session = sessions[viewState.selectedIndex]
        let name = session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
        attachment.attach(to: name)
    }

    private mutating func resumeHistorySelected(trimmed: Bool = false) {
        guard history.indices.contains(viewState.selectedIndex) else { return }
        do {
            let wasTrimmed = try actions.resumeHistory(history[viewState.selectedIndex], trimmed: trimmed)
            let item = history[viewState.selectedIndex]
            viewState.toggleHistory()
            viewState.showNotice(wasTrimmed ? "Resumed \(item.title) (trimmed)" : "Resumed \(item.title)")
        } catch {
            viewState.showNotice(error.localizedDescription)
        }
    }

    private mutating func createShellSession() {
        do {
            let id = try actions.createShellSession()
            viewState.showNotice("Created \(id)")
        } catch {
            viewState.showNotice("Unable to create session: \(error.localizedDescription)")
        }
    }

    private mutating func recoverSelected() {
        guard sessions.indices.contains(viewState.selectedIndex) else { return }
        let session = sessions[viewState.selectedIndex]
        do {
            try actions.recover(session)
            viewState.showNotice("Recovered \(session.id)")
        } catch {
            viewState.showNotice("Unable to recover \(session.id): \(error.localizedDescription)")
        }
    }

    private mutating func closeSelected() {
        guard sessions.indices.contains(viewState.selectedIndex) else { return }
        let session = sessions[viewState.selectedIndex]
        actions.close(session)
        viewState.showNotice("Closed \(session.id)")
    }

    private mutating func removeSelected() {
        guard sessions.indices.contains(viewState.selectedIndex) else { return }
        let session = sessions[viewState.selectedIndex]
        actions.remove(session)
        viewState.showNotice("Removed \(session.id)")
    }

}

private var app = BanyanTUI()
app.run()
