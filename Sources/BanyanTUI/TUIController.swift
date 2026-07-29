import BanyanCore
import Foundation

struct BanyanTUI {
    private let tmux: any TmuxTerminalBackend
    private let attachment: TUIAttachment
    private let actions: any SessionListActions
    private let input: any TUIInput
    private let output: any TUIOutput
    private let renderer: any TUIRenderer
    private let currentDirectory: String
    private var model: SessionListModel

    init(
        backend: any TmuxTerminalBackend,
        dataSource: any SessionListDataSource,
        actions: any SessionListActions,
        input: any TUIInput,
        output: any TUIOutput,
        processRunner: any TUIProcessRunner,
        renderer: any TUIRenderer,
        currentDirectory: String
    ) {
        self.tmux = backend
        self.attachment = TUIAttachment(
            tmux: backend,
            processRunner: processRunner,
            output: output
        )
        self.model = SessionListModel(dataSource: dataSource)
        self.actions = actions
        self.input = input
        self.output = output
        self.renderer = renderer
        self.currentDirectory = currentDirectory
    }

    mutating func run() {
        while true {
            reload()
            render()

            guard let action = input.readAction() else { break }
            guard handle(action) else { return }
        }
    }

    private mutating func handle(_ action: SessionListAction) -> Bool {
        switch action {
            case .quit:
                return false
            case .toggleHistory:
                model.toggleHistory()
            case .searchHistory:
                searchHistory()
            case .next:
                model.moveNext()
            case .previous:
                model.movePrevious()
            case .pageNext:
                model.movePageNext()
            case .pagePrevious:
                model.movePagePrevious()
            case .refresh:
                model.refresh()
            case .recover:
                if !model.showingHistory { recoverSelected() }
            case .newSession:
                if !model.showingHistory { createShellSession() }
            case .newCustomSession:
                if !model.showingHistory { createCustomSession() }
            case .rename:
                if !model.showingHistory { renameSelected() }
            case .close:
                if !model.showingHistory { closeSelected() }
            case .remove:
                if !model.showingHistory { removeSelected() }
            case .activate:
                input.restore()
                if model.showingHistory {
                    resumeHistorySelected()
                } else {
                    attachSelected()
                }
                input.enterRaw()
            case .trimResume:
                if model.showingHistory { resumeHistorySelected(trimmed: true) }
            case .unknown:
                break
        }
        return true
    }

    private mutating func reload() {
        model.reload()
    }

    private func render() {
        let output = renderer.render(
            sessions: model.sessions,
            history: model.history,
            showingHistory: model.showingHistory,
            selectedIndex: model.selectedIndex,
            notice: model.notice,
            tmux: tmux
        )
        self.output.write(output, terminator: "")
    }

    private func attachSelected() {
        guard let session = model.selectedSession else { return }
        attachment.attach(to: session.launchRequest.sessionName)
    }

    private mutating func resumeHistorySelected(trimmed: Bool = false) {
        guard let item = model.selectedHistory else { return }
        do {
            let wasTrimmed = try actions.resumeHistory(item, trimmed: trimmed)
            model.toggleHistory()
            model.showNotice(wasTrimmed ? "Resumed \(item.title) (trimmed)" : "Resumed \(item.title)")
        } catch {
            model.showNotice(error.localizedDescription)
        }
    }

    private mutating func createShellSession() {
        do {
            let id = try actions.createShellSession(cwd: currentDirectory)
            model.showNotice("Created \(id)")
        } catch {
            model.showNotice("Unable to create session: \(error.localizedDescription)")
        }
    }

    private mutating func createCustomSession() {
        guard let title = input.readLine(prompt: "Title (blank for Shell): "),
              let cwd = input.readLine(prompt: "Working directory (blank for current): "),
              let command = input.readLine(prompt: "Command (blank for shell): ") else {
            return
        }
        do {
            let id = try actions.createSession(
                title: title,
                cwd: cwd.isEmpty ? currentDirectory : cwd,
                command: command
            )
            model.showNotice("Created \(id)")
        } catch {
            model.showNotice("Unable to create session: \(error.localizedDescription)")
        }
    }

    private mutating func renameSelected() {
        guard let session = model.selectedSession else { return }
        let title = input.readLine(prompt: "New title (blank cancels): ")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return }
        actions.rename(session, title: title)
        model.showNotice("Renamed \(session.id)")
    }

    private mutating func searchHistory() {
        let query = input.readLine(prompt: "History search (blank clears): ") ?? ""
        if !model.showingHistory { model.toggleHistory() }
        model.setHistoryFilter(query)
        model.showNotice(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "History filter cleared"
            : "History filter: \(query.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private mutating func recoverSelected() {
        guard let session = model.selectedSession else { return }
        do {
            try actions.recover(session)
            model.showNotice("Recovered \(session.id)")
        } catch {
            model.showNotice("Unable to recover \(session.id): \(error.localizedDescription)")
        }
    }

    private mutating func closeSelected() {
        guard let session = model.selectedSession else { return }
        actions.close(session)
        model.showNotice("Closed \(session.id)")
    }

    private mutating func removeSelected() {
        guard let session = model.selectedSession else { return }
        actions.remove(session)
        model.showNotice("Removed \(session.id)")
    }

}
