import BanyanCore
import Foundation

struct BanyanTUI {
    private let tmux: any TmuxTerminalBackend
    private let attachment: TUIAttachment
    private let actions: any SessionListActions
    private let input: any TUIInput
    private let output: any TUIOutput
    private let currentDirectory: String
    private var model: SessionListModel

    init(
        backend: any TmuxTerminalBackend,
        dataSource: any SessionListDataSource,
        actions: any SessionListActions,
        input: any TUIInput,
        output: any TUIOutput,
        currentDirectory: String
    ) {
        self.tmux = backend
        self.attachment = TUIAttachment(tmux: backend, output: output)
        self.model = SessionListModel(dataSource: dataSource)
        self.actions = actions
        self.input = input
        self.output = output
        self.currentDirectory = currentDirectory
    }

    mutating func run() {
        while true {
            reload()
            render()

            guard let byte = input.readByte() else { break }
            guard handle(SessionListAction(byte: byte)) else { return }
        }
    }

    private mutating func handle(_ action: SessionListAction) -> Bool {
        switch action {
            case .quit:
                return false
            case .toggleHistory:
                model.toggleHistory()
            case .next:
                model.moveNext()
            case .previous:
                model.movePrevious()
            case .refresh:
                model.refresh()
            case .recover:
                if !model.showingHistory { recoverSelected() }
            case .newSession:
                if !model.showingHistory { createShellSession() }
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
        let output = TerminalRenderer.render(
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
