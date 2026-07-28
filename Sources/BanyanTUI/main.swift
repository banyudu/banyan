import BanyanCore
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private struct BanyanTUI {
    private let database: SessionDatabase
    private let tmux = TmuxBackend.shared
    private let catalog: SessionCatalog
    private var sessions: [SessionSnapshot] = []
    private var history: [ImportedAgentSession] = []
    private var showingHistory = false
    private var selectedIndex = 0
    private var notice: String?

    init() {
        let database = SessionDatabase()
        self.database = database
        self.catalog = SessionCatalog(
            persistence: database,
            runtime: SessionRuntimeCoordinator()
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
                selectedIndex = 0
                continue
            case .next:
                selectedIndex = min(selectedIndex + 1, max(0, visibleRowCount - 1))
            case .previous:
                selectedIndex = max(0, selectedIndex - 1)
            case .refresh:
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
            history = AgentSessionHistoryImporter.load(maxPerProvider: 30)
            selectedIndex = min(selectedIndex, max(0, history.count - 1))
            return
        }
        let stored = database.load()
        let processTable = ProcessTable.snapshot()
        let synchronizer = SessionStatusSynchronizer(
            backend: tmux,
            processDescendants: { rootPID in processTable.descendants(of: rootPID) }
        )
        let updated = synchronizer.synchronize(stored)
        if updated != stored { database.save(updated) }
        sessions = updated.filter { $0.status != .closed }
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
        let item = history[selectedIndex]
        guard let sourceID = AgentSessionHistory.sourceID(
            fromImportedSessionID: item.id,
            provider: item.provider
        ) else {
            notice = "Unable to resume \(item.title)"
            return
        }

        let resumeSourceID: String
        if trimmed,
           let prepared = TranscriptResumePreparer.prepare(
               provider: item.provider,
               sourceID: sourceID,
               cwd: item.cwd,
               transcriptURL: item.transcriptURL
           ) {
            resumeSourceID = prepared.newSourceID
        } else {
            resumeSourceID = sourceID
        }

        guard let command = AgentSessionHistory.resumeCommand(
            provider: item.provider,
            sourceID: resumeSourceID,
            cwd: item.cwd
        ) else {
            notice = "Unable to resume \(item.title)"
            return
        }

        let id = uniqueSessionID(prefix: "\(item.provider.rawValue)-\(resumeSourceID.prefix(8))")
        let now = Date()
        let request = SessionLaunchRequest(
            sessionName: TmuxBackend.sessionName(for: id),
            cwd: item.cwd,
            command: command
        )
        let snapshot = SessionSnapshot(
            id: id,
            tmuxSessionName: request.sessionName,
            title: item.title,
            reportedTitle: item.title,
            cwd: item.cwd,
            command: command,
            status: .running,
            tone: .blue,
            createdAt: now,
            updatedAt: now
        )
        do {
            try catalog.create(snapshot: snapshot, launchRequest: request)
            showingHistory = false
            selectedIndex = 0
            notice = trimmed ? "Resumed \(item.title) (trimmed)" : "Resumed \(item.title)"
        } catch {
            notice = "Unable to resume \(item.title): \(error.localizedDescription)"
        }
    }

    private mutating func createShellSession() {
        let id = uniqueSessionID()
        let cwd = FileManager.default.currentDirectoryPath
        let request = SessionLaunchRequest(
            sessionName: TmuxBackend.sessionName(for: id),
            cwd: cwd,
            command: ""
        )
        do {
            let now = Date()
            let snapshot = SessionSnapshot(
                id: id,
                tmuxSessionName: request.sessionName,
                title: "Shell",
                reportedTitle: nil,
                cwd: cwd,
                command: "",
                status: .running,
                tone: .blue,
                createdAt: now,
                updatedAt: now
            )
            try catalog.create(snapshot: snapshot, launchRequest: request)
            notice = "Created \(id)"
        } catch {
            notice = "Unable to create session: \(error.localizedDescription)"
        }
    }

    private mutating func recoverSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        let request = SessionLaunchRequest(
            sessionName: tmuxName(for: session),
            cwd: session.cwd,
            command: session.command
        )
        do {
            try catalog.recover(snapshot: session, launchRequest: request)
            notice = "Recovered \(session.id)"
        } catch {
            notice = "Unable to recover \(session.id): \(error.localizedDescription)"
        }
    }

    private mutating func closeSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        catalog.close(snapshot: session)
        notice = "Closed \(session.id)"
    }

    private mutating func removeSelected() {
        guard sessions.indices.contains(selectedIndex) else { return }
        let session = sessions[selectedIndex]
        catalog.remove(snapshot: session)
        notice = "Removed \(session.id)"
    }

    private func uniqueSessionID(prefix: String = "tui-shell") -> String {
        let existingIDs = Set(database.load().map(\.id))
        var candidate = prefix
        var suffix = 2
        while existingIDs.contains(candidate) || tmux.hasSession(named: TmuxBackend.sessionName(for: candidate)) {
            candidate = "\(prefix)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func tmuxName(for session: SessionSnapshot) -> String {
        session.tmuxSessionName ?? TmuxBackend.sessionName(for: session.id)
    }

}

private var app = BanyanTUI()
app.run()
