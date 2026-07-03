import BanyanCore
import Foundation

struct SidebarSessionItem: Identifiable {
    let session: BanyanSession
    let depth: Int

    var id: String {
        session.id
    }
}

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
    private var supervisorTimer: Timer?
    private var isSupervisorTickRunning = false

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
            return active.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        }
    }

    var sidebarSessions: [SidebarSessionItem] {
        let active = visibleSessions
        let activeIDs = Set(active.map(\.id))
        let grouped = Dictionary(grouping: active) { session in
            session.parentSessionID.flatMap { activeIDs.contains($0) ? $0 : nil }
        }
        var visited = Set<String>()
        var result: [SidebarSessionItem] = []

        func append(_ session: BanyanSession, depth: Int) {
            guard !visited.contains(session.id) else { return }
            visited.insert(session.id)
            result.append(SidebarSessionItem(session: session, depth: depth))
            for child in grouped[session.id] ?? [] {
                append(child, depth: depth + 1)
            }
        }

        for root in grouped[nil] ?? [] {
            append(root, depth: 0)
        }
        for session in active where !visited.contains(session.id) {
            append(session, depth: 0)
        }
        return result
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
                id: uniqueID(snapshot.id, avoidingLiveTmuxSessions: false),
                tmuxSessionName: tmuxSessionName,
                title: restoredTitle(from: snapshot),
                isTitlePinned: snapshot.isTitlePinned,
                cwd: snapshot.cwd,
                command: snapshot.command,
                status: snapshot.status == .closed && tmuxBackend.hasSession(named: tmuxSessionName) ? .running : snapshot.status,
                tone: snapshot.tone,
                parentSessionID: snapshot.parentSessionID,
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
            let id = uniqueID(String(tmuxSessionName.dropFirst("banyan-".count)), avoidingLiveTmuxSessions: false)
            let session = BanyanSession(
                id: id,
                tmuxSessionName: tmuxSessionName,
                title: defaultTitle(for: NSHomeDirectory()),
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

    func startSupervisor() {
        guard supervisorTimer == nil else { return }
        runSupervisorTick()
        supervisorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runSupervisorTick()
            }
        }
    }

    @discardableResult
    func forkSelectedSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        return spawn(cwd: cwd, command: "", parentSessionID: selectedSession?.id)
    }

    @discardableResult
    func spawn(
        id proposedID: String? = nil,
        title proposedTitle: String? = nil,
        cwd proposedCWD: String? = nil,
        command proposedCommand: String? = nil,
        parentSessionID proposedParentSessionID: String? = nil,
        tone: SessionTone = .blue
    ) -> BanyanSession {
        let baseID = sanitizeID(proposedID ?? proposedTitle ?? "session")
        let id = uniqueID(baseID, avoidingLiveTmuxSessions: true)
        let cwd = resolvedWorkingDirectory(proposedCWD)
        let command = proposedCommand ?? ""
        let hasExplicitTitle = proposedTitle?.isEmpty == false
        let title = hasExplicitTitle ? proposedTitle! : defaultTitle(for: cwd)
        let parentSessionID = normalizedParentSessionID(proposedParentSessionID)
        let session = BanyanSession(
            id: id,
            tmuxSessionName: TmuxBackend.sessionName(for: id),
            title: title,
            isTitlePinned: hasExplicitTitle,
            cwd: cwd,
            command: command,
            tone: tone,
            parentSessionID: parentSessionID,
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

    func tick(id: String? = nil) throws {
        if let id {
            guard sessions.contains(where: { $0.id == id }) else {
                throw ControlError.notFound(id)
            }
            runSupervisorTick(sessionID: id)
        } else {
            runSupervisorTick()
        }
        saveSessions()
    }

    func close(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        detachChildren(of: id, to: session.parentSessionID)
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
        let parentSessionID = sessions[index].parentSessionID
        detachChildren(of: id, to: parentSessionID)
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

    func activeChildCount(of id: String) -> Int {
        sessions.filter { $0.status != .closed && $0.parentSessionID == id }.count
    }

    func hasActiveChildren(_ id: String) -> Bool {
        activeChildCount(of: id) > 0
    }

    func resolvedParentSessionIDForSpawn(_ parentSessionID: String?) throws -> String? {
        guard let parentSessionID = normalizedParentSessionID(parentSessionID) else {
            return nil
        }
        guard sessions.contains(where: { $0.id == parentSessionID && $0.status != .closed }) else {
            throw ControlError.badRequest("No active parent session found for id '\(parentSessionID)'")
        }
        return parentSessionID
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
                isTitlePinned: $0.isTitlePinned,
                cwd: $0.cwd,
                command: $0.command,
                status: $0.status,
                tone: $0.tone,
                parentSessionID: $0.parentSessionID,
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
        guard result.status == .asking || result.status == .needInput else { return }
        guard ![.executing, .longRunningShell, .subagents].contains(session.status) else { return }
        session.mark(status: result.status, tone: result.tone)
    }

    private func runSupervisorTick(sessionID: String? = nil) {
        guard !isSupervisorTickRunning else { return }
        isSupervisorTickRunning = true
        defer { isSupervisorTickRunning = false }

        let processTable = ProcessTable.snapshot()
        let supervisor = AgentSupervisor(backend: tmuxBackend) { rootPID in
            processTable.descendants(of: rootPID)
        }

        for session in sessions where session.status != .closed && (sessionID == nil || session.id == sessionID) {
            guard !session.isRestored else { continue }
            guard let result = supervisor.inspect(
                tmuxSessionName: session.tmuxSessionName,
                launchCommand: session.command,
                currentStatus: session.status
            ) else {
                continue
            }
            if session.status != result.status || session.tone != result.tone {
                session.mark(status: result.status, tone: result.tone)
            }
        }
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

    private func normalizedParentSessionID(_ parentSessionID: String?) -> String? {
        let trimmed = parentSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func detachChildren(of parentID: String, to newParentID: String?) {
        let parentIDForChildren = normalizedParentSessionID(newParentID)
        for session in sessions where session.parentSessionID == parentID {
            session.parentSessionID = parentIDForChildren
            session.touch()
        }
    }

    private func defaultTitle(for cwd: String) -> String {
        PathDisplayName.make(path: cwd)
    }

    private func restoredTitle(from snapshot: SessionSnapshot) -> String {
        if !snapshot.isTitlePinned, isGenericDefaultTitle(snapshot.title) {
            return defaultTitle(for: snapshot.cwd)
        }
        return snapshot.title
    }

    private func isGenericDefaultTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty
            || value == "shell"
            || value.hasPrefix("shell-")
            || value == "session"
            || value.hasPrefix("session-")
    }

    private func sanitizeID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "session" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "session" : String(cleaned)
    }

    private func uniqueID(_ baseID: String, avoidingLiveTmuxSessions: Bool) -> String {
        if isAvailableID(baseID, avoidingLiveTmuxSessions: avoidingLiveTmuxSessions) {
            return baseID
        }
        var index = 2
        while !isAvailableID("\(baseID)-\(index)", avoidingLiveTmuxSessions: avoidingLiveTmuxSessions) {
            index += 1
        }
        return "\(baseID)-\(index)"
    }

    private func isAvailableID(_ id: String, avoidingLiveTmuxSessions: Bool) -> Bool {
        guard !sessions.contains(where: { $0.id == id }) else {
            return false
        }
        if avoidingLiveTmuxSessions, tmuxBackend.hasSession(named: TmuxBackend.sessionName(for: id)) {
            return false
        }
        return true
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
