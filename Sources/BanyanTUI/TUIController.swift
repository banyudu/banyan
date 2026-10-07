import BanyanCore
import Foundation

struct BanyanTUI {
    private let tmux: any TmuxTerminalBackend
    private let attachment: TUIAttachment
    private let actions: any SessionListActions
    private let input: any TUIInput
    private let output: any TUIOutput
    private let currentDirectory: String
    private let puckClient: PuckDaemonClient?
    private var model: SessionListModel
    private let events: TUIEvents
    private let terminal: EmbeddedTerminal
    private let environment: [String: String]
    private var screenRenderer = EmbeddedScreenRenderer()
    private var focused = false
    private var inputRouter = TerminalInputRouter()
    private var inputGeneration = 0
    private var sidebarInput = SidebarInputRouter()
    private var navigationGeneration = 0

    init(
        backend: any TmuxTerminalBackend,
        dataSource: any SessionListDataSource,
        actions: any SessionListActions,
        input: any TUIInput,
        output: any TUIOutput,
        processRunner: any TUIProcessRunner,
        puckClient: PuckDaemonClient? = nil,
        currentDirectory: String,
        events: TUIEvents,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.tmux = backend
        self.attachment = TUIAttachment(
            tmux: backend,
            processRunner: processRunner,
            output: output
        )
        self.model = SessionListModel(dataSource: dataSource, puckClient: puckClient)
        self.actions = actions
        self.input = input
        self.output = output
        self.currentDirectory = currentDirectory
        self.puckClient = puckClient
        self.events = events
        self.terminal = EmbeddedTerminal { events.post(.redraw) }
        self.environment = environment
    }

    mutating func run() {
        output.write("\u{1b}[?1049h\u{1b}[?7l", terminator: "")
        defer {
            terminal.stop()
            output.write("\u{1b}[0m\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?7h\u{1b}[0 q\u{1b}[?25h\u{1b}[?1049l", terminator: "")
        }
        reload()
        syncTerminal()
        render()
        while let event = input.readEvent(events: events) {
            switch event {
            case .quit: return
            case .redraw: break
            case .resize:
                let layout = input.layout
                terminal.resize(columns: layout.terminalColumns, rows: layout.terminalRows)
            case .flushInput(let token):
                if token == inputGeneration && focused { terminal.send(inputRouter.flushEscape()) }
            case .flushNavigation(let token):
                if token == navigationGeneration { sidebarInput.flushEscape() }
            case .action(let action):
                guard handle(action) else { return }
                reload()
                syncTerminal()
            case .input(let bytes):
                guard handleInput(bytes) else { return }
                navigationGeneration += 1
                if sidebarInput.hasPendingEscape {
                    let token = navigationGeneration, events = events
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                        events.post(.flushNavigation(token))
                    }
                }
            }
            render()
        }
    }

    private mutating func handleInput(_ bytes: [UInt8]) -> Bool {
        if focused { return routeTerminalInput(bytes) }
        for (index, byte) in bytes.enumerated() {
            guard let event = sidebarInput.consume(byte) else { continue }
            switch event {
            case .fallback:
                fallbackAttach()
            case .action(let action):
                guard handle(action) else { return false }
            }
            reload()
            syncTerminal()
            // Focus changes can share a read with the first shell/sidebar command.
            if focused { return routeTerminalInput(Array(bytes.dropFirst(index + 1))) }
        }
        return true
    }

    private mutating func routeTerminalInput(_ bytes: [UInt8]) -> Bool {
        let snapshot = terminal.snapshot()
        for event in inputRouter.consume(bytes, layout: input.layout,
                                         mouseEnabled: snapshot.grid?.mouseEnabled == true,
                                         bracketedPaste: snapshot.grid?.bracketedPaste == true) {
            switch event {
            case .bytes(let bytes):
                if focused { terminal.send(bytes) }
                else if !handleInput(bytes) { return false }
            case .sidebar: focused = false
            case .next: model.moveNext(); syncTerminal()
            case .previous: model.movePrevious(); syncTerminal()
            }
        }
        inputGeneration += 1
        if inputRouter.hasPendingEscape {
            let token = inputGeneration, events = events
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
                events.post(.flushInput(token))
            }
        }
        return true
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
                if model.showingHistory {
                    resumeHistorySelected()
                } else if let session = model.selectedPuckSession, let puckClient {
                    suspendScreen()
                    input.restore()
                    screenRenderer.invalidate()
                    do {
                        try PuckTUI(input: input, output: output,
                                    currentDirectory: currentDirectory).attach(session.id, client: puckClient)
                    } catch {
                        model.showNotice("Puck: \(error.localizedDescription)")
                    }
                    input.enterRaw()
                    resumeScreen()
                } else {
                    if terminal.snapshot().message != nil { terminal.stop(); syncTerminal() }
                    focused = terminal.sessionName != nil
                }
            case .trimResume:
                if model.showingHistory { resumeHistorySelected(trimmed: true) }
            case .puck:
                terminal.stop()
                suspendScreen()
                PuckTUI(input: input, output: output, currentDirectory: currentDirectory)
                    .run(client: puckClient ?? PuckDaemonClient())
                model.refresh()
                screenRenderer.invalidate()
                resumeScreen()
            case .unknown:
                break
        }
        return true
    }

    private mutating func reload() {
        model.reload()
    }

    private mutating func render() {
        let state = terminal.snapshot()
        let frame = screenRenderer.render(model: model, layout: input.layout, grid: state.grid,
                                          focused: focused, terminalMessage: state.message)
        if !frame.isEmpty { output.write(frame, terminator: "") }
    }

    private mutating func syncTerminal() {
        guard !model.showingHistory, let session = model.selectedSession else {
            terminal.stop(); focused = false; inputRouter = TerminalInputRouter(); return
        }
        let name = session.launchRequest.sessionName
        guard terminal.sessionName != name else { return }
        inputRouter = TerminalInputRouter()
        inputGeneration += 1
        let layout = input.layout
        terminal.connect(executable: tmux.executableURL, arguments: tmux.attachArguments(for: name),
                         environment: environment, sessionName: name,
                         columns: layout.terminalColumns, rows: layout.terminalRows)
    }

    private mutating func fallbackAttach() {
        terminal.stop()
        input.restore()
        suspendScreen()
        attachSelected()
        input.enterRaw()
        resumeScreen()
        syncTerminal()
    }

    private func suspendScreen() {
        output.write("\u{1b}[0m\u{1b}[?7h\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1006l\u{1b}[?2004l\u{1b}[?25h", terminator: "")
    }

    private mutating func resumeScreen() {
        // DECSET 1049 is a mode, not a nested stack: an external tmux/Puck view
        // may have left it. Re-enter before repainting to protect the host shell.
        output.write("\u{1b}[?1049h\u{1b}[?7l", terminator: "")
        screenRenderer.invalidate()
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
        screenRenderer.invalidate()
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
        screenRenderer.invalidate()
        guard let session = model.selectedSession else { return }
        let title = input.readLine(prompt: "New title (blank cancels): ")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return }
        actions.rename(session, title: title)
        model.showNotice("Renamed \(session.id)")
    }

    private mutating func searchHistory() {
        screenRenderer.invalidate()
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
