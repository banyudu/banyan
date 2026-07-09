import BanyanCore
import Foundation
import AppKit

struct SidebarSessionItem: Identifiable {
    let session: BanyanSession
    let depth: Int
    let titleOverride: String?

    init(session: BanyanSession, depth: Int, titleOverride: String? = nil) {
        self.session = session
        self.depth = depth
        self.titleOverride = titleOverride
    }

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

struct LivePromptTitleMatchInput: Equatable {
    let id: String
    let cwd: String
    let createdAt: Date
    let resetAt: Date?
    let provider: CodingAgentProvider?
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
    private var historyImportTimer: Timer?
    private var isSupervisorTickRunning = false
    private var isHistoryImportRunning = false
    private var latestImportedHistory: [ImportedAgentSession] = []
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

    var sessionSidebarGroups: [SidebarSessionGroup] {
        let active = visibleSessions.filter { !$0.isImportedHistory }
        var sessionsByProject: [String: [BanyanSession]] = [:]
        var orderedProjectIDs: [String] = []

        for session in active {
            if sessionsByProject[session.projectGroupID] == nil {
                orderedProjectIDs.append(session.projectGroupID)
            }
            sessionsByProject[session.projectGroupID, default: []].append(session)
        }

        let groups: [SidebarSessionGroup] = orderedProjectIDs.compactMap { projectID in
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

        return groups
    }

    var historySidebarGroup: SidebarSessionGroup? {
        let historyItems = sidebarHistoryItems
        guard !historyItems.isEmpty else { return nil }
        return SidebarSessionGroup(
            id: "history",
            title: "History",
            items: historyItems
        )
    }

    var sidebarGroups: [SidebarSessionGroup] {
        var groups = sessionSidebarGroups
        if let historySidebarGroup {
            groups.append(historySidebarGroup)
        }
        return groups
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

    private var sidebarHistoryItems: [SidebarSessionItem] {
        sessions
            .filter { $0.status != .closed && $0.isImportedHistory }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(10)
            .map {
                SidebarSessionItem(
                    session: $0,
                    depth: 0,
                    titleOverride: Self.historySidebarTitle(
                        projectName: $0.projectName,
                        displayTitle: $0.displayTitle,
                        issueID: $0.titleLinkLabel
                    )
                )
            }
    }

    nonisolated static func historySidebarTitle(projectName: String, displayTitle: String, issueID: String?) -> String {
        let title = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let issueID, !issueID.isEmpty else {
            return "\(projectName) · \(title)"
        }
        let firstToken = title.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        if firstToken?.caseInsensitiveCompare(issueID) == .orderedSame {
            return title
        }
        return "\(issueID.uppercased()) · \(title)"
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

    func refreshImportedHistory(spawnDefaultIfEmpty: Bool = false) {
        runHistoryImport(spawnDefaultIfEmpty: spawnDefaultIfEmpty)
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

    func startHistoryImport() {
        guard historyImportTimer == nil else { return }
        runHistoryImport()
        historyImportTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHistoryImport()
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
        session.reattachTerminalClient()
        selectedSessionID = id
        saveSessions()
    }

    func restart(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.restartBackingSession()
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

    func showFindInSelectedSession() {
        guard let selectedSession, !selectedSession.isImportedHistory else { return }
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        selectedSession.terminalView.performFindPanelAction(item)
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
        if sessions[index].isImportedHistory {
            sessions[index].status = .closed
            if selectedSessionID == id {
                selectedSessionID = visibleSessions.first?.id
            }
            return
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

    @discardableResult
    func resumeImportedHistory(id: String, prompt: String? = nil) throws -> BanyanSession {
        guard let history = sessions.first(where: { $0.id == id && $0.isImportedHistory }) else {
            throw ControlError.notFound(id)
        }
        guard let provider = history.agentProvider,
              let sourceID = AgentSessionHistoryImporter.sourceID(fromImportedSessionID: history.id, provider: provider),
              let command = AgentSessionHistoryImporter.resumeCommand(
                provider: provider,
                sourceID: sourceID,
                cwd: history.cwd,
                prompt: prompt
              ) else {
            throw ControlError.badRequest("Session history item '\(id)' cannot be resumed")
        }
        return spawn(
            id: "\(provider.rawValue)-\(String(sourceID.prefix(8)))",
            title: history.displayTitle,
            cwd: history.cwd,
            command: command,
            tone: .blue
        )
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
            if self.tmuxBackend.hasSession(named: session.tmuxSessionName) {
                session.detachTerminalClient()
            } else {
                try? self.close(id: session.id)
            }
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
        guard let session = selectedSession, session.status != .closed, !session.isImportedHistory else { return }
        session.start()
    }

    private func saveSessions() {
        let snapshots = sessions.filter { !$0.isImportedHistory }.map {
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

    private func runHistoryImport(spawnDefaultIfEmpty: Bool = false) {
        guard !isHistoryImportRunning else { return }
        isHistoryImportRunning = true
        Task.detached(priority: .utility) {
            let imported = AgentSessionHistoryImporter.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyImportedHistory(imported)
                self.isHistoryImportRunning = false
                if spawnDefaultIfEmpty, self.visibleSessions.isEmpty {
                    self.spawn(cwd: NSHomeDirectory())
                }
            }
        }
    }

    private func applyImportedHistory(_ imported: [ImportedAgentSession]) {
        latestImportedHistory = imported
        let importedIDs = Set(imported.map(\.id))
        let staleImportedIDs = Set(sessions.compactMap { session in
            session.isImportedHistory && !importedIDs.contains(session.id) && session.status != .closed
                ? session.id
                : nil
        })
        if !staleImportedIDs.isEmpty {
            sessions.removeAll { staleImportedIDs.contains($0.id) }
        }

        var sessionIndexesByID = Dictionary(
            uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) }
        )
        for history in imported {
            if let index = sessionIndexesByID[history.id] {
                let existing = sessions[index]
                guard existing.isImportedHistory, existing.status != .closed else { continue }
                if !Self.importedHistorySession(existing, matches: history) {
                    replaceImportedSession(history, at: index)
                }
            } else {
                sessions.append(makeImportedSession(history))
                sessionIndexesByID[history.id] = sessions.endIndex - 1
            }
        }
        refreshLiveAgentTitles(from: imported)

        if let selectedSessionID, !visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = visibleSessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = visibleSessions.first?.id
        }
    }

    private func replaceImportedSession(_ history: ImportedAgentSession, at index: Int) {
        sessions[index] = makeImportedSession(history)
    }

    static func importedHistorySession(_ session: BanyanSession, matches history: ImportedAgentSession) -> Bool {
        session.id == history.id
            && session.isImportedHistory
            && session.title == history.title
            && session.cwd == history.cwd
            && session.command == history.provider.defaultExecutableName
            && session.status == .completed
            && session.tone == .neutral
            && session.historyTranscriptURL == history.transcriptURL
            && session.createdAt == history.createdAt
    }

    private func makeImportedSession(_ history: ImportedAgentSession) -> BanyanSession {
        let session = BanyanSession(
            id: history.id,
            tmuxSessionName: TmuxBackend.sessionName(for: history.id),
            title: history.title,
            generatedTitle: nil,
            isTitlePinned: true,
            cwd: history.cwd,
            command: history.provider.defaultExecutableName,
            status: .completed,
            tone: .neutral,
            historyTranscriptURL: history.transcriptURL,
            createdAt: history.createdAt,
            updatedAt: history.updatedAt,
            isRestored: true,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize
        )
        attach(session)
        return session
    }

    private func refreshLiveAgentTitles(from imported: [ImportedAgentSession]) {
        let candidates = imported.filter { [.claude, .codex].contains($0.provider) }
        guard !candidates.isEmpty else { return }

        let liveSessions = sessions.filter {
            !$0.isImportedHistory
                && $0.status != .closed
                && !$0.isTitlePinned
                && ($0.agentProvider == nil || [.claude, .codex].contains($0.agentProvider!))
        }
        let inputs = liveSessions.map {
            LivePromptTitleMatchInput(
                id: $0.id,
                cwd: $0.cwd,
                createdAt: $0.createdAt,
                resetAt: $0.lastConversationResetAt,
                provider: $0.agentProvider
            )
        }
        let matchesBySessionID = Self.bestPromptTitleAssignments(
            for: inputs,
            in: candidates
        )

        for session in liveSessions {
            guard let match = matchesBySessionID[session.id] else { continue }
            if session.detectedAgentProvider != match.provider {
                session.markDetectedAgentProvider(match.provider)
            }
            session.markFirstPromptTitle(match.title)
        }
    }

    nonisolated static func bestPromptTitleMatch(
        sessionCWD: String,
        sessionCreatedAt: Date,
        sessionResetAt: Date?,
        provider: CodingAgentProvider?,
        in candidates: [ImportedAgentSession]
    ) -> ImportedAgentSession? {
        let sessionCWD = standardizedPath(sessionCWD)
        let matchWindow: TimeInterval = 5 * 60
        let resetWindow: TimeInterval = 30
        let matchingCandidates = candidates.filter {
            (provider == nil || $0.provider == provider)
                && standardizedPath($0.cwd) == sessionCWD
        }

        if let sessionResetAt {
            return matchingCandidates
                .filter { $0.updatedAt >= sessionResetAt.addingTimeInterval(-resetWindow) }
                .max { $0.updatedAt < $1.updatedAt }
        }

        return matchingCandidates
            .filter { abs($0.createdAt.timeIntervalSince(sessionCreatedAt)) <= matchWindow }
            .min {
                abs($0.createdAt.timeIntervalSince(sessionCreatedAt)) < abs($1.createdAt.timeIntervalSince(sessionCreatedAt))
            }
    }

    nonisolated static func bestPromptTitleAssignments(
        for sessions: [LivePromptTitleMatchInput],
        in candidates: [ImportedAgentSession]
    ) -> [String: ImportedAgentSession] {
        struct Pair {
            let sessionID: String
            let candidate: ImportedAgentSession
            let score: TimeInterval
        }

        let optionsBySessionID = Dictionary(uniqueKeysWithValues: sessions.map { session in
            let options = promptTitleMatchCandidates(for: session, in: candidates).map { candidate in
                Pair(
                    sessionID: session.id,
                    candidate: candidate,
                    score: promptTitleMatchScore(session: session, candidate: candidate)
                )
            }
            .sorted {
                if $0.score == $1.score {
                    return $0.candidate.updatedAt > $1.candidate.updatedAt
                }
                return $0.score < $1.score
            }
            return (session.id, options)
        })
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let orderedSessionIDs = sessions
            .filter { optionsBySessionID[$0.id]?.isEmpty == false }
            .sorted {
                let lhsCount = optionsBySessionID[$0.id]?.count ?? 0
                let rhsCount = optionsBySessionID[$1.id]?.count ?? 0
                if lhsCount == rhsCount {
                    return $0.createdAt < $1.createdAt
                }
                return lhsCount < rhsCount
            }
            .map(\.id)

        var sessionIDByCandidateID: [String: String] = [:]

        func assign(_ sessionID: String, visitedCandidateIDs: inout Set<String>) -> Bool {
            guard let options = optionsBySessionID[sessionID] else { return false }
            for pair in options {
                let candidateID = pair.candidate.id
                guard !visitedCandidateIDs.contains(candidateID) else { continue }
                visitedCandidateIDs.insert(candidateID)

                if let displacedSessionID = sessionIDByCandidateID[candidateID] {
                    guard assign(displacedSessionID, visitedCandidateIDs: &visitedCandidateIDs) else {
                        continue
                    }
                }

                sessionIDByCandidateID[candidateID] = sessionID
                return true
            }
            return false
        }

        for sessionID in orderedSessionIDs {
            var visitedCandidateIDs = Set<String>()
            _ = assign(sessionID, visitedCandidateIDs: &visitedCandidateIDs)
        }

        var result: [String: ImportedAgentSession] = [:]
        for (candidateID, sessionID) in sessionIDByCandidateID {
            guard let candidate = candidateByID[candidateID] else {
                continue
            }
            result[sessionID] = candidate
        }

        return result
    }

    nonisolated private static func promptTitleMatchCandidates(
        for session: LivePromptTitleMatchInput,
        in candidates: [ImportedAgentSession]
    ) -> [ImportedAgentSession] {
        let sessionCWD = standardizedPath(session.cwd)
        let matchWindow: TimeInterval = 5 * 60
        let resetWindow: TimeInterval = 30
        let matchingCandidates = candidates.filter {
            (session.provider == nil || $0.provider == session.provider)
                && standardizedPath($0.cwd) == sessionCWD
        }

        if let resetAt = session.resetAt {
            return matchingCandidates.filter {
                $0.updatedAt >= resetAt.addingTimeInterval(-resetWindow)
            }
        }

        return matchingCandidates.filter {
            abs($0.createdAt.timeIntervalSince(session.createdAt)) <= matchWindow
        }
    }

    nonisolated private static func promptTitleMatchScore(
        session: LivePromptTitleMatchInput,
        candidate: ImportedAgentSession
    ) -> TimeInterval {
        if session.resetAt != nil {
            return -candidate.updatedAt.timeIntervalSinceReferenceDate
        }
        return abs(candidate.createdAt.timeIntervalSince(session.createdAt))
    }

    nonisolated private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
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
            let info = SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
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
        var didUpdateProvider = false
        for result in results {
            guard let session = sessions.first(where: { $0.id == result.id }), session.status != .closed else {
                continue
            }
            if session.detectedAgentProvider != result.provider {
                session.markDetectedAgentProvider(result.provider)
                didUpdateProvider = true
            }
            session.updateCurrentDirectory(result.currentPath)
            if session.status != result.status || session.tone != result.tone {
                session.mark(status: result.status, tone: result.tone)
            }
        }
        if didUpdateProvider {
            refreshLiveAgentTitles(from: latestImportedHistory)
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
