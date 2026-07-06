import BanyanCore
import Foundation
import AppKit

struct SidebarSessionItem: Identifiable {
    let session: BanyanSession
    let depth: Int

    var id: String {
        session.id
    }
}

struct SidebarSessionGroup: Identifiable {
    let id: String
    let title: String
    let items: [SidebarSessionItem]
}

private struct SupervisorSessionInput {
    let id: String
    let tmuxSessionName: String
    let command: String
    let status: SessionStatus
}

private struct SupervisorSessionResult {
    let id: String
    let status: SessionStatus
    let tone: SessionTone
    let provider: CodingAgentProvider?
    let currentPath: String?
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [BanyanSession] = []
    @Published private(set) var terminalFocusRequestID = UUID()
    @Published private(set) var selectedContextInfo: SessionContextInfo?
    @Published var addSessionDraft: AddSessionDraft?
    @Published var selectedSessionID: String? {
        didSet {
            saveWorkspace()
            startSelectedSessionIfNeeded()
            requestTerminalFocus()
            refreshSelectedContextInfo(force: true)
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
    @Published private var pendingCloseSessionID: String?

    private var controlServer: ControlServer?
    private let persistence = SessionPersistence()
    private let detector = AgentStateDetector()
    private let tmuxBackend = TmuxBackend.shared
    private var didLoadPersistedSessions = false
    private var supervisorTimer: Timer?
    private var isSupervisorTickRunning = false
    private var selectedContextTask: Task<Void, Never>?
    private var selectedContextSignature: String?
    private var selectedContextResolvedAt = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        var defaultTheme: TerminalTheme = .system
        if let rawTheme = defaults.string(forKey: "terminalTheme"),
           let theme = TerminalTheme.fromPersistedRawValue(rawTheme) {
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

    var sidebarGroups: [SidebarSessionGroup] {
        let active = visibleSessions
        var sessionsByProject: [String: [BanyanSession]] = [:]
        var orderedProjectIDs: [String] = []

        for session in active {
            if sessionsByProject[session.projectGroupID] == nil {
                orderedProjectIDs.append(session.projectGroupID)
            }
            sessionsByProject[session.projectGroupID, default: []].append(session)
        }

        return orderedProjectIDs.compactMap { projectID in
            guard let projectSessions = sessionsByProject[projectID],
                  let firstSession = projectSessions.first else {
                return nil
            }
            return SidebarSessionGroup(
                id: projectID,
                title: firstSession.projectGroupTitle,
                items: sidebarItems(for: projectSessions)
            )
        }
    }

    var sidebarSessions: [SidebarSessionItem] {
        sidebarGroups.flatMap(\.items)
    }

    private func sidebarItems(for sessions: [BanyanSession]) -> [SidebarSessionItem] {
        let activeIDs = Set(sessions.map(\.id))
        let grouped = Dictionary(grouping: sessions) { session in
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
        for session in sessions where !visited.contains(session.id) {
            append(session, depth: 0)
        }
        return result
    }

    var selectedSession: BanyanSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var pendingCloseSession: BanyanSession? {
        guard let pendingCloseSessionID else { return nil }
        return sessions.first { $0.id == pendingCloseSessionID }
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
                titleURL: snapshot.titleURL,
                generatedTitle: snapshot.generatedTitle,
                isTitlePinned: snapshot.isTitlePinned,
                cwd: snapshot.cwd,
                command: snapshot.command,
                status: Self.restoredStatus(
                    snapshotStatus: snapshot.status,
                    backingSessionExists: tmuxBackend.hasSession(named: tmuxSessionName)
                ),
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
        }
        if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            selectedSessionID = visibleSessions.first?.id
        }
        startSelectedSessionIfNeeded()
        refreshSelectedContextInfo(force: true)
        saveSessions()
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer(store: self)
        server.start()
        controlServer = server
    }

    nonisolated static func restoredStatus(snapshotStatus: SessionStatus, backingSessionExists: Bool) -> SessionStatus {
        if snapshotStatus == .closed {
            return .closed
        }
        return snapshotStatus
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
    func spawnSiblingSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        return spawn(cwd: cwd, command: "", parentSessionID: selectedSession?.parentSessionID)
    }

    func showCustomSessionSheet() {
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        addSessionDraft = .sibling(cwd: cwd)
    }

    func showChildSessionSheet() {
        guard let selectedSession else { return }
        addSessionDraft = .child(of: selectedSession)
    }

    @discardableResult
    func spawn(
        id proposedID: String? = nil,
        title proposedTitle: String? = nil,
        titleURL proposedTitleURL: String? = nil,
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
                titleURL: normalizedTitleURL(proposedTitleURL),
                generatedTitle: nil,
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
        refreshSelectedContextInfo(force: true)
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

    func mark(id: String, status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil, titleURL: String? = nil) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.mark(status: status, tone: tone, title: title, titleURL: normalizedTitleURL(titleURL))
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

    func openSelectedLinearIssue() {
        guard let url = selectedLinearIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openSelectedPullRequest() {
        guard let url = selectedPullRequestURL else { return }
        NSWorkspace.shared.open(url)
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

    func selectNextSession() {
        selectAdjacentSession(direction: .next)
    }

    func selectPreviousSession() {
        selectAdjacentSession(direction: .previous)
    }

    func selectSession(shortcutIndex: Int) {
        guard let id = SessionSelectionNavigator.directID(
            in: sidebarSessions.map(\.id),
            oneBasedIndex: shortcutIndex
        ) else {
            return
        }
        selectedSessionID = id
    }

    func requestCloseSelectedSession() {
        guard let selectedSession else { return }
        requestClose(id: selectedSession.id)
    }

    var selectedLinearIssueURL: URL? {
        if let value = selectedContextInfo?.linearIssueURL, let url = URL(string: value) {
            return url
        }
        return nil
    }

    var selectedPullRequestURL: URL? {
        guard let value = selectedContextInfo?.pullRequestURL else { return nil }
        return URL(string: value)
    }

    func requestClose(id: String) {
        if hasActiveChildren(id) {
            pendingCloseSessionID = id
        } else {
            try? close(id: id)
        }
    }

    func confirmPendingClose() {
        guard let id = pendingCloseSessionID else { return }
        pendingCloseSessionID = nil
        try? close(id: id)
    }

    func cancelPendingClose() {
        pendingCloseSessionID = nil
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
                guard let self else { return }
                self.saveSessions()
                if self.selectedSessionID == session.id {
                    self.refreshSelectedContextInfo()
                }
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
        session.onProcessExit = { [weak self, weak session] _ in
            guard let self, let session, session.status != .closed else { return }
            try? self.close(id: session.id)
        }
    }

    private func requestTerminalFocus() {
        terminalFocusRequestID = UUID()
    }

    private func applyAppearance() {
        sessions.forEach {
            $0.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
        }
    }

    private func startSelectedSessionIfNeeded() {
        guard let session = selectedSession, session.status != .closed else { return }
        session.start()
    }

    private func saveSessions() {
        let snapshots = sessions.map {
            SessionSnapshot(
                id: $0.id,
                tmuxSessionName: $0.tmuxSessionName,
                title: $0.title,
                titleURL: $0.titleURL,
                reportedTitle: $0.reportedTitle,
                generatedTitle: $0.generatedTitle,
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
        let inputs = sessions.compactMap { session -> SupervisorSessionInput? in
            guard session.status != .closed && (sessionID == nil || session.id == sessionID) else {
                return nil
            }
            guard session.isProcessStarted else { return nil }
            return SupervisorSessionInput(
                id: session.id,
                tmuxSessionName: session.tmuxSessionName,
                command: session.command,
                status: session.status
            )
        }
        guard !inputs.isEmpty else { return }

        isSupervisorTickRunning = true

        Task.detached(priority: .utility) { [weak self] in
            let backend = TmuxBackend.shared
            let processTable = ProcessTable.snapshot()
            let supervisor = AgentSupervisor(backend: backend) { rootPID in
                processTable.descendants(of: rootPID)
            }

            let results = inputs.compactMap { input -> SupervisorSessionResult? in
                guard let result = supervisor.inspect(
                    tmuxSessionName: input.tmuxSessionName,
                    launchCommand: input.command,
                    currentStatus: input.status
                ) else {
                    return nil
                }
                if result.status == .closed && backend.hasSession(named: input.tmuxSessionName) {
                    return nil
                }
                return SupervisorSessionResult(
                    id: input.id,
                    status: result.status,
                    tone: result.tone,
                    provider: result.provider,
                    currentPath: result.currentPath
                )
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applySupervisorResults(results)
                self.isSupervisorTickRunning = false
                self.saveSessions()
                self.refreshSelectedContextInfoIfStale()
            }
        }
    }

    private func refreshSelectedContextInfo(force: Bool = false) {
        guard let session = selectedSession, session.status != .closed else {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextSignature = nil
            selectedContextInfo = nil
            return
        }

        let input = SessionContextLookupInput(
            sessionID: session.id,
            cwd: session.cwd,
            title: session.title,
            titleURL: session.titleURL,
            displayTitle: session.displayTitle
        )
        guard force || input.signature != selectedContextSignature else { return }

        selectedContextSignature = input.signature
        if selectedContextInfo?.signature != input.signature {
            selectedContextInfo = nil
        }
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .utility) {
            let info = SessionContextResolver.resolve(input: input)
            await MainActor.run { [weak self] in
                guard let self,
                      self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
            }
        }
    }

    private func refreshSelectedContextInfoIfStale() {
        guard Date().timeIntervalSince(selectedContextResolvedAt) > 30 else { return }
        refreshSelectedContextInfo(force: true)
    }

    private func applySupervisorResults(_ results: [SupervisorSessionResult]) {
        for result in results {
            guard let session = sessions.first(where: { $0.id == result.id }), session.status != .closed else {
                continue
            }
            if session.detectedAgentProvider != result.provider {
                session.markDetectedAgentProvider(result.provider)
            }
            session.updateCurrentDirectory(result.currentPath)
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

    private func normalizedTitleURL(_ titleURL: String?) -> String? {
        let trimmed = titleURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func detachChildren(of parentID: String, to newParentID: String?) {
        let parentIDForChildren = normalizedParentSessionID(newParentID)
        for session in sessions where session.parentSessionID == parentID {
            session.parentSessionID = parentIDForChildren
            session.touch()
        }
    }

    private func selectAdjacentSession(direction: SessionSelectionDirection) {
        guard let id = SessionSelectionNavigator.adjacentID(
            in: sidebarSessions.map(\.id),
            selectedID: selectedSessionID,
            direction: direction
        ) else {
            return
        }
        selectedSessionID = id
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
