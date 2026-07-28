import BanyanCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct BanyanTUI {
    private let tmux = TmuxBackend.shared
    private let dataSource: TUISessionDataSource
    private let actions: TUISessionActions
    private var sessions: [SessionSnapshot] = []
    private var history: [ImportedAgentSession] = []
    private var showingHistory = false
    private var historyNeedsReload = true
    private var selectedIndex = 0
    private var notice: String?

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
            switch TUIAction(byte: byte) {
            case .quit:
                return
            case .toggleHistory:
                showingHistory.toggle()
                if showingHistory { historyNeedsReload = true }
                selectedIndex = 0
                continue
            case .next:
                selectedIndex = min(selectedIndex + 1, max(0, visibleRowCount - 1))
            case .previous:
                selectedIndex = max(0, selectedIndex - 1)
            case .refresh:
                if showingHistory { historyNeedsReload = true }
                continue
            case .recover:
                if !showingHistory { recoverSelected() }
            case .newSession:
                if !showingHistory { createShellSession() }
            case .close:
                if !showingHistory { closeSelected() }
            case .remove:
                if !showingHistory { removeSelected() }
            case .activate:
                terminal.restore()
                if showingHistory {
                    resumeHistorySelected()
                } else {
                    attachSelected()
                }
                terminal.enterRaw()
            case .trimResume:
                if showingHistory { resumeHistorySelected(trimmed: true) }
            case .unknown:
                continue
            }
        }
    }

    private mutating func reload() {
        if showingHistory {
            if historyNeedsReload {
                history = dataSource.loadHistory()
                historyNeedsReload = false
            }
            selectedIndex = min(selectedIndex, max(0, history.count - 1))
            return
        }
        sessions = dataSource.loadActiveSessions()
        selectedIndex = min(selectedIndex, max(0, sessions.count - 1))
    }

    private var visibleRowCount: Int {
        showingHistory ? history.count : sessions.count
    }

    private func render() {
        let output = TerminalRenderer.render(
            sessions: sessions,
            history: history,
            showingHistory: showingHistory,
            selectedIndex: selectedIndex,
            notice: notice,
            tmux: tmux
        )
        print(output, terminator: "")
        fflush(stdout)
    }

    private func attachSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        let name = session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
        print("\u{1b}[2J\u{1b}[H", terminator: "")
        fflush(stdout)

        let process = Process()
        process.executableURL = tmux.executableURL
        process.arguments = tmux.attachArguments(for: name)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("Unable to attach to \(name): \(error.localizedDescription)")
        }
    }

    private mutating func resumeHistorySelected(trimmed: Bool = false) {
        guard history.indices.contains(selectedIndex) else { return }
        do {
            let wasTrimmed = try actions.resumeHistory(history[selectedIndex], trimmed: trimmed)
            let item = history[selectedIndex]
            showingHistory = false
            selectedIndex = 0
            notice = wasTrimmed ? "Resumed \(item.title) (trimmed)" : "Resumed \(item.title)"
        } catch {
            notice = error.localizedDescription
        }
    }

    private mutating func createShellSession() {
        do {
            let id = try actions.createShellSession()
            notice = "Created \(id)"
        } catch {
            notice = "Unable to create session: \(error.localizedDescription)"
        }
    }

    private mutating func recoverSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        do {
            try actions.recover(session)
            notice = "Recovered \(session.id)"
        } catch {
            notice = "Unable to recover \(session.id): \(error.localizedDescription)"
        }
    }

    private mutating func closeSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        actions.close(session)
        notice = "Closed \(session.id)"
    }

    private mutating func removeSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        actions.remove(session)
        notice = "Removed \(session.id)"
    }

    private func tmuxName(for session: SessionSnapshot) -> String {
        actions.sessionName(for: session)
    }

}

private var app = BanyanTUI()
app.run()
