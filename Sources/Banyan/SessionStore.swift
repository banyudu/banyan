import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [BanyanSession] = []
    @Published var selectedSessionID: String? {
        didSet {
            saveWorkspace()
        }
    }
    @Published var sortMode: SortMode = .manual {
        didSet {
            saveWorkspace()
        }
    }
    @Published var terminalTheme: TerminalTheme = .system {
        didSet {
            saveWorkspace()
            applyAppearance()
        }
    }
    @Published var terminalFontFamily: String = "Menlo" {
        didSet {
            saveWorkspace()
            applyAppearance()
        }
    }
    @Published var terminalFontSize: Double = 13 {
        didSet {
            saveWorkspace()
            applyAppearance()
        }
    }

    private var controlServer: ControlServer?
    private let persistence = SessionPersistence()
    private let detector = AgentStateDetector()
    private let tmuxBackend = TmuxBackend.shared
    private var didLoadPersistedSessions = false

    init() {
        let defaults = UserDefaults.standard
        var defaultTheme: TerminalTheme = .system
        if let rawTheme = defaults.string(forKey: "terminalTheme"),
           let theme = TerminalTheme(rawValue: rawTheme) {
            defaultTheme = theme
        }
        var defaultFontFamily = "Menlo"
        if let fontFamily = defaults.string(forKey: "terminalFontFamily") {
            defaultFontFamily = fontFamily
        }
        var defaultFontSize: Double = 13
        let storedFontSize = defaults.double(forKey: "terminalFontSize")
        if storedFontSize > 0 {
            defaultFontSize = storedFontSize
        }
        let workspace = persistence.loadWorkspace(
            defaults: WorkspaceSnapshot(
                selectedSessionID: nil,
                sortMode: .manual,
                terminalTheme: defaultTheme,
                terminalFontFamily: defaultFontFamily,
                terminalFontSize: defaultFontSize
            )
        )
        selectedSessionID = workspace.selectedSessionID
        sortMode = workspace.sortMode
        terminalTheme = workspace.terminalTheme
        terminalFontFamily = workspace.terminalFontFamily
        terminalFontSize = workspace.terminalFontSize
    }

    var visibleSessions: [BanyanSession] {
        let active = sessions.filter { $0.status != .closed }
        switch sortMode {
        case .manual:
            return active
        case .status:
            return active.sorted {
                if $0.status.priority == $1.status.priority {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.status.priority < $1.status.priority
            }
        case .updated:
            return active.sorted { $0.updatedAt > $1.updatedAt }
        case .title:
            return active.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var selectedSession: BanyanSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func loadPersistedSessionsIfNeeded() {
        guard !didLoadPersistedSessions else { return }
        didLoadPersistedSessions = true
        let snapshots = persistence.load()
        var loadedTmuxSessionNames = Set<String>()
        for snapshot in snapshots {
            let tmuxSessionName = snapshot.tmuxSessionName ?? TmuxBackend.sessionName(for: snapshot.id)
            let session = BanyanSession(
                id: uniqueID(snapshot.id),
                tmuxSessionName: tmuxSessionName,
                title: snapshot.title,
                cwd: snapshot.cwd,
                command: snapshot.command,
                status: snapshot.status == .closed && tmuxBackend.hasSession(named: tmuxSessionName) ? .running : snapshot.status,
                tone: snapshot.tone,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                isRestored: true,
                theme: terminalTheme,
                fontFamily: terminalFontFamily,
                fontSize: terminalFontSize
            )
            session.reportedTitle = snapshot.reportedTitle
            attach(session)
            sessions.append(session)
            loadedTmuxSessionNames.insert(session.tmuxSessionName)
            if session.status != .closed, tmuxBackend.hasSession(named: session.tmuxSessionName) {
                session.start()
            }
        }
        for tmuxSessionName in tmuxBackend.listBanyanSessions() where !loadedTmuxSessionNames.contains(tmuxSessionName) {
            let id = uniqueID(String(tmuxSessionName.dropFirst("banyan-".count)))
            let session = BanyanSession(
                id: id,
                tmuxSessionName: tmuxSessionName,
                title: id,
                cwd: NSHomeDirectory(),
                command: "",
                status: .running,
                tone: .blue,
                isRestored: true,
                theme: terminalTheme,
                fontFamily: terminalFontFamily,
                fontSize: terminalFontSize
            )
            attach(session)
            sessions.append(session)
            session.start()
        }
        if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            selectedSessionID = visibleSessions.first?.id
        }
        saveSessions()
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer(store: self)
        server.start()
        controlServer = server
    }

    @discardableResult
    func forkSelectedSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        return spawn(title: "Shell", cwd: cwd, command: "")
    }

    @discardableResult
    func spawn(
        id proposedID: String? = nil,
        title proposedTitle: String? = nil,
        cwd proposedCWD: String? = nil,
        command proposedCommand: String? = nil,
        tone: SessionTone = .blue
    ) -> BanyanSession {
        let baseID = sanitizeID(proposedID ?? proposedTitle ?? "session")
        let id = uniqueID(baseID)
        let cwd = resolvedWorkingDirectory(proposedCWD)
        let command = proposedCommand ?? ""
        let title = proposedTitle?.isEmpty == false ? proposedTitle! : id
        let session = BanyanSession(
            id: id,
            tmuxSessionName: TmuxBackend.sessionName(for: id),
            title: title,
            cwd: cwd,
            command: command,
            tone: tone,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize
        )
        attach(session)
        sessions.append(session)
        selectedSessionID = session.id
        session.start()
        saveSessions()
        return session
    }

    func respawn(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.start()
        selectedSessionID = id
        saveSessions()
    }

    func mark(id: String, status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.mark(status: status, tone: tone, title: title)
        saveSessions()
    }

    func close(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.terminate(markClosed: true)
        if selectedSessionID == id {
            selectedSessionID = visibleSessions.first?.id
        }
        saveSessions()
    }

    func remove(id: String) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        sessions[index].killBackingSession()
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = visibleSessions.first?.id
        }
        saveSessions()
    }

    func select(id: String) {
        selectedSessionID = id
    }

    private func attach(_ session: BanyanSession) {
        session.onDidChange = { [weak self] in
            Task { @MainActor in
                self?.saveSessions()
            }
        }
        session.onOutput = { [weak self, weak session] text in
            guard let self, let session else { return }
            self.detectAttention(in: text, for: session)
        }
        session.onStatusSignal = { [weak session] status in
            guard let session else { return }
            AttentionNotifier.shared.notifyIfNeeded(session: session, status: status)
        }
    }

    private func applyAppearance() {
        sessions.forEach {
            $0.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
        }
    }

    private func saveSessions() {
        let snapshots = sessions.map {
            SessionSnapshot(
                id: $0.id,
                tmuxSessionName: $0.tmuxSessionName,
                title: $0.title,
                reportedTitle: $0.reportedTitle,
                cwd: $0.cwd,
                command: $0.command,
                status: $0.status,
                tone: $0.tone,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        persistence.save(snapshots)
    }

    private func saveWorkspace() {
        persistence.saveWorkspace(
            WorkspaceSnapshot(
                selectedSessionID: selectedSessionID,
                sortMode: sortMode,
                terminalTheme: terminalTheme,
                terminalFontFamily: terminalFontFamily,
                terminalFontSize: terminalFontSize
            )
        )
    }

    private func detectAttention(in text: String, for session: BanyanSession) {
        guard let result = detector.detect(in: text), session.status != .closed else { return }
        session.mark(status: result.status, tone: result.tone)
    }

    private func resolvedWorkingDirectory(_ cwd: String?) -> String {
        let raw = cwd?.isEmpty == false ? cwd! : FileManager.default.currentDirectoryPath
        let expanded = NSString(string: raw).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        return NSHomeDirectory()
    }

    private func sanitizeID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "session" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "session" : String(cleaned)
    }

    private func uniqueID(_ baseID: String) -> String {
        if !sessions.contains(where: { $0.id == baseID }) {
            return baseID
        }
        var index = 2
        while sessions.contains(where: { $0.id == "\(baseID)-\(index)" }) {
            index += 1
        }
        return "\(baseID)-\(index)"
    }
}

enum ControlError: LocalizedError {
    case notFound(String)
    case badRequest(String)

    var code: String {
        switch self {
        case .notFound: return "not_found"
        case .badRequest: return "bad_request"
        }
    }

    var httpStatus: Int {
        switch self {
        case .notFound: return 404
        case .badRequest: return 400
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No session found for id '\(id)'"
        case .badRequest(let message): return message
        }
    }
}
