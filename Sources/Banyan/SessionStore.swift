import BanyanCore
import Foundation
import AppKit
import SwiftUI

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

enum SidebarMode: String, CaseIterable, Identifiable {
    case sessions
    case linear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .linear: return "Linear"
        }
    }
}

enum LinearIssueListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case starting(String)
}

struct HandoffJob: Equatable, Identifiable {
    let id: String
    let sessionID: String
    let title: String
    let cwd: String
    let startedAt: Date
}

private enum HandoffDispatchError: Error {
    case commandUnavailable
    case failed(Int32)
}

private struct SupervisorSessionInput {
    let id: String
    let tmuxSessionName: String
    let command: String
    let status: SessionStatus
    let isAwaitingAttach: Bool
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
    private static let scratchWindowIdentifier = NSUserInterfaceItemIdentifier("banyan.scratch-terminal")

    @Published private(set) var sessions: [BanyanSession] = []
    @Published private(set) var terminalFocusRequestID = UUID()
    @Published private(set) var scratchTerminalFocusRequestID = UUID()
    @Published private(set) var scratchSession: BanyanSession?
    @Published private(set) var selectedContextInfo: SessionContextInfo? {
        didSet {
            refreshSelectedLinearIssue()
        }
    }
    @Published private(set) var selectedLinearIssueDetails: LinearIssueDetails?
    @Published private(set) var selectedLinearIssueLoadState: LinearIssueLoadState = .idle
    @Published var isPullRequestPreviewPresented = false
    @Published private(set) var selectedPullRequestDetails: GitHubPullRequestDetails?
    @Published private(set) var selectedPullRequestLoadState: GitHubPullRequestLoadState = .idle
    @Published var sidebarMode: SidebarMode = .sessions {
        didSet {
            if sidebarMode == .linear {
                refreshLinearIssueListIfNeeded()
            }
        }
    }
    @Published private(set) var linearIssues: [LinearIssueSummary] = []
    @Published private(set) var linearIssueWorkflowStates: [LinearWorkflowState] = []
    @Published private(set) var linearIssueListLoadState: LinearIssueListLoadState = .idle
    @Published var selectedLinearListIssueID: String? {
        didSet {
            refreshSelectedLinearListIssue()
        }
    }
    @Published private(set) var selectedLinearListIssueDetails: LinearIssueDetails?
    @Published private(set) var selectedLinearListIssueLoadState: LinearIssueLoadState = .idle
    @Published private(set) var pendingHandoffJobs: [HandoffJob] = []
    @Published var addSessionDraft: AddSessionDraft?
    @Published var selectedSessionID: String? {
        didSet {
            if oldValue != selectedSessionID {
                PerformanceTelemetry.shared.beginSessionSwitch(
                    from: oldValue,
                    to: selectedSessionID,
                    visibleSessionCount: visibleSessions.count
                )
            }
            saveWorkspaceSoon()
            requestTerminalFocus()
            if oldValue != selectedSessionID {
                closePullRequestPreview()
            }
            refreshSelectedContextInfo(force: true)
        }
    }
    @Published var sortMode: SortMode = .manual {
        didSet {
            saveWorkspace()
        }
    }
    /// Deliberately not persisted: a stale filter on launch would look like lost history.
    @Published var historyFilterText: String = ""
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
    /// Per-project last-used "new session" kind, keyed by project group ID. Drives
    /// the project header's split "+" button so it reopens whatever was launched
    /// last for that project. Persisted in `UserDefaults`.
    @Published private var projectLaunchByGroup: [String: NewSessionLaunch] = [:]
    private static let projectLaunchDefaultsKey = "projectNewSessionLaunch"

    private var controlServer: ControlServer?
    private let persistence = SessionPersistence()
    /// Serial queue for the SQLite session write, keeping the full-table rewrite off
    /// the main thread. Serial + ordered so concurrent saves can't collide on the
    /// `BEGIN IMMEDIATE` transaction.
    private let sessionPersistenceQueue = DispatchQueue(label: "com.banyan.session-persistence", qos: .utility)
    /// Last snapshot set written to disk; lets `saveSessions()` skip the frequent
    /// no-op saves (e.g. every supervisor tick) that re-serialized unchanged state.
    private var lastSavedSessionSnapshots: [SessionSnapshot]?
    private let detector = AgentStateDetector()
    private let tmuxBackend = TmuxBackend.shared
    private var didLoadPersistedSessions = false
    private var supervisorTimer: Timer?
    /// Effective cadence the live `supervisorTimer` was installed with, so we can
    /// skip re-installing the timer when the adaptive interval is unchanged.
    private var currentSupervisorInterval: TimeInterval = 0
    /// App-lifecycle / thermal / power observers that re-evaluate the supervisor
    /// cadence. Installed once; retained so they outlive `addObserver`.
    private var supervisorLifecycleObservers: [NSObjectProtocol] = []
    private var isSupervisorTickRunning = false
    private var isHistoryImportRunning = false
    private var isHistoryImportPending = false
    private var latestImportedHistory: [ImportedAgentSession] = []
    private var selectedContextTask: Task<Void, Never>?
    private var selectedContextSignature: String?
    private var selectedContextResolvedAt = Date.distantPast
    /// Network/git-derived context keyed by `SessionContextResolver.cacheKey`.
    /// Lets title-text churn and the periodic stale refresh reuse a recent result
    /// instead of re-spawning `git`/`linear`/`gh` on every resolve.
    private var selectedContextCache: [String: (info: SessionContextInfo, at: Date)] = [:]
    // Linear titles and PR URLs for a given cwd/issue/PR change rarely, so a long TTL
    // keeps the subprocess-free fast path serving most resolves. At 180s the periodic
    // 30s stale-refresh forced a real `linear`/`gh` resolve every ~3min per selected
    // session; 600s cuts that ~3x while keeping the titlebar acceptably fresh.
    private let selectedContextCacheTTL: TimeInterval = 600
    private var selectedLinearIssueTask: Task<Void, Never>?
    private var selectedLinearIssueStatusTask: Task<Void, Never>?
    private var selectedLinearIssueStatusTimer: Timer?
    private var selectedLinearIssueIdentifier: String?
    private var selectedPullRequestTask: Task<Void, Never>?
    private var selectedPullRequestPreviewURL: URL?
    private var didLoadCachedLinearIssues = false
    private var linearIssueListTask: Task<Void, Never>?
    private var selectedLinearListIssueTask: Task<Void, Never>?
    private var workspaceSaveTask: Task<Void, Never>?
    private var scratchWindow: NSWindow?
    private var scratchWindowDelegate: ScratchTerminalWindowDelegate?
    private var isClosingScratchTerminal = false

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
        if let stored = defaults.dictionary(forKey: Self.projectLaunchDefaultsKey) as? [String: String] {
            projectLaunchByGroup = stored.compactMapValues(NewSessionLaunch.init(rawValue:))
        }

        // Sessions now persist off the main thread; drain the queue on quit so the
        // final change isn't lost between the async enqueue and process exit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSessionSaves()
        }
    }

    /// Blocks until the serial session-persistence queue drains. Safe to call from a
    /// non-isolated context (only touches the immutable, Sendable queue).
    nonisolated private func flushPendingSessionSaves() {
        sessionPersistenceQueue.sync {}
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

        return groups.sorted {
            let titleComparison = $0.title.localizedCaseInsensitiveCompare($1.title)
            if titleComparison == .orderedSame {
                return $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
            }
            return titleComparison == .orderedAscending
        }
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

    /// Unfiltered, History is a scrollable "recent work" shelf. A search is a request
    /// for a specific session, so it reaches past that shelf into the full backlog.
    static let historySidebarBrowseLimit = 30
    static let historySidebarSearchLimit = 100

    var hasLocalHistorySessions: Bool {
        sessions.contains(where: Self.isLocalHistorySession)
    }

    private var sidebarHistoryItems: [SidebarSessionItem] {
        let query = historyFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = query.isEmpty ? Self.historySidebarBrowseLimit : Self.historySidebarSearchLimit
        return sessions
            .filter(Self.isLocalHistorySession)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { session in
                (
                    session: session,
                    title: Self.historySidebarTitle(
                        projectName: session.projectName,
                        displayTitle: session.displayTitle,
                        issueID: session.titleLinkLabel
                    )
                )
            }
            .filter { Self.matchesHistoryFilter(title: $0.title, query: query) }
            .prefix(limit)
            .map { SidebarSessionItem(session: $0.session, depth: 0, titleOverride: $0.title) }
    }

    /// Matches against the row's rendered title (project · issue · title), so what the
    /// user reads is what they can search. Every whitespace-separated token must appear,
    /// which lets "clawly eng-74" narrow without demanding the exact rendered order.
    nonisolated static func matchesHistoryFilter(title: String, query: String) -> Bool {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            title.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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

    static func isLocalHistorySession(_ session: BanyanSession) -> Bool {
        guard session.status == .closed, !session.isImportedHistory else {
            return false
        }
        guard let provider = session.agentProvider, [.codex, .claude].contains(provider) else {
            return false
        }
        return session.titleLinkLabel != nil
    }

    nonisolated static func staleTmuxSessionNames(liveSessionNames: [String], persistedSessionNames: Set<String>) -> [String] {
        liveSessionNames
            .filter { !persistedSessionNames.contains($0) }
            .sorted()
    }

    var selectedSession: BanyanSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var hasScratchTerminal: Bool {
        scratchSession != nil
    }

    var pendingCloseSession: BanyanSession? {
        guard let pendingCloseSessionID else { return nil }
        return sessions.first { $0.id == pendingCloseSessionID }
    }

    var pendingCloseHasActiveChildren: Bool {
        guard let pendingCloseSessionID else { return false }
        return hasActiveChildren(pendingCloseSessionID)
    }

    var pendingCloseHasOngoingAgent: Bool {
        guard let session = pendingCloseSession else { return false }
        return Self.isOngoingCodexOrClaudeSession(status: session.status, provider: session.agentProvider)
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
                titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
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
                agentSessionID: snapshot.agentSessionID,
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
            if session.status != .closed {
                loadedTmuxSessionNames.insert(session.tmuxSessionName)
            }
        }
        for tmuxSessionName in Self.staleTmuxSessionNames(
            liveSessionNames: tmuxBackend.listBanyanSessions(),
            persistedSessionNames: loadedTmuxSessionNames
        ) {
            tmuxBackend.killSession(named: tmuxSessionName)
        }
        if let selectedSessionID, visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = selectedSessionID
        } else {
            selectedSessionID = visibleSessions.first?.id
        }
        refreshSelectedContextInfo(force: true)
        saveSessions()
    }

    func refreshImportedHistory(spawnDefaultIfEmpty: Bool = false) {
        runHistoryImport(spawnDefaultIfEmpty: spawnDefaultIfEmpty)
    }

    func refreshLinearIssueListIfNeeded() {
        loadCachedLinearIssuesIfNeeded()
        guard linearIssueListTask == nil else { return }
        switch linearIssueListLoadState {
        case .idle, .loaded, .failed:
            refreshLinearIssueList()
        case .loading, .starting:
            break
        }
    }

    func refreshLinearIssueList() {
        loadCachedLinearIssuesIfNeeded()
        guard linearIssueListTask == nil else {
            linearDebugLog("list refresh ignored because refresh is already running")
            return
        }
        let hasStaleIssues = !linearIssues.isEmpty
        linearIssueListLoadState = hasStaleIssues ? .loaded : .loading
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        linearDebugLog("list refresh start cwd=\(cwd) staleCount=\(linearIssues.count) staleStates=[\(linearIssueStateCountSummary(linearIssues))]")
        linearIssueListTask = Task.detached(priority: .utility) {
            do {
                async let issuesRequest = LinearIssueClient.fetchIssueList(cwd: cwd)
                async let workflowStatesRequest = LinearIssueClient.fetchWorkflowStates(cwd: cwd)
                let issues = try await issuesRequest
                let workflowStates: [LinearWorkflowState]?
                do {
                    workflowStates = try await workflowStatesRequest
                } catch {
                    linearDebugLog("workflow states refresh failed error=\(error.localizedDescription)")
                    workflowStates = nil
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.linearIssueListTask = nil
                    self.linearIssues = issues
                    let workflowStateSource = workflowStates ?? self.linearIssueWorkflowStates
                    self.linearIssueWorkflowStates = Self.mergedWorkflowStates(workflowStateSource, issues: issues)
                    linearDebugLog("list refresh applied issueCount=\(issues.count) issueStates=[\(linearIssueStateCountSummary(issues))] workflowStateCount=\(self.linearIssueWorkflowStates.count) workflowStates=[\(linearWorkflowStateSummary(self.linearIssueWorkflowStates))]")
                    if let selectedLinearListIssueID = self.selectedLinearListIssueID,
                       !issues.contains(where: { $0.identifier == selectedLinearListIssueID }) {
                        self.selectedLinearListIssueID = issues.first?.identifier
                    } else if self.selectedLinearListIssueID == nil {
                        self.selectedLinearListIssueID = issues.first?.identifier
                    }
                    self.persistence.saveLinearIssueListCache(
                        LinearIssueListCacheSnapshot(
                            issues: issues,
                            workflowStates: self.linearIssueWorkflowStates,
                            selectedIssueID: self.selectedLinearListIssueID,
                            updatedAt: Date()
                        )
                    )
                    self.linearIssueListLoadState = .loaded
                }
            } catch {
                linearDebugLog("list refresh failed error=\(error.localizedDescription)")
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.linearIssueListTask = nil
                    self.linearIssueListLoadState = self.linearIssues.isEmpty
                        ? .failed("Unable to load Linear issues")
                        : .loaded
                }
            }
        }
    }

    private func loadCachedLinearIssuesIfNeeded() {
        guard !didLoadCachedLinearIssues else { return }
        didLoadCachedLinearIssues = true
        guard linearIssues.isEmpty,
              let cache = persistence.loadLinearIssueListCache(),
              !cache.issues.isEmpty else {
            return
        }

        linearIssues = cache.issues
        linearIssueWorkflowStates = Self.mergedWorkflowStates(cache.workflowStates ?? [], issues: cache.issues)
        linearDebugLog("list cache loaded issueCount=\(cache.issues.count) issueStates=[\(linearIssueStateCountSummary(cache.issues))] workflowStateCount=\(linearIssueWorkflowStates.count) selectedIssueID=\(cache.selectedIssueID ?? "nil") updatedAt=\(cache.updatedAt)")
        let cachedIssueIDs = Set(cache.issues.map(\.identifier))
        if let selectedLinearListIssueID, cachedIssueIDs.contains(selectedLinearListIssueID) {
            linearIssueListLoadState = .loaded
            return
        }
        if let selectedIssueID = cache.selectedIssueID,
           cachedIssueIDs.contains(selectedIssueID) {
            selectedLinearListIssueID = selectedIssueID
        } else {
            selectedLinearListIssueID = cache.issues.first?.identifier
        }
        linearIssueListLoadState = .loaded
    }

    private static func mergedWorkflowStates(
        _ workflowStates: [LinearWorkflowState],
        issues: [LinearIssueSummary]
    ) -> [LinearWorkflowState] {
        var statesByID: [String: LinearWorkflowState] = [:]
        for state in workflowStates {
            statesByID[state.id] = state
        }
        for issue in issues {
            statesByID[issue.state.id] = issue.state
        }
        return statesByID.values.sorted {
            switch ($0.position, $1.position) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    private func mergeLinearWorkflowStates(_ workflowStates: [LinearWorkflowState]) {
        guard !workflowStates.isEmpty else { return }
        let mergedWorkflowStates = Self.mergedWorkflowStates(
            linearIssueWorkflowStates + workflowStates,
            issues: linearIssues
        )
        guard mergedWorkflowStates != linearIssueWorkflowStates else { return }
        linearIssueWorkflowStates = mergedWorkflowStates
        guard !linearIssues.isEmpty else { return }
        persistence.saveLinearIssueListCache(
            LinearIssueListCacheSnapshot(
                issues: linearIssues,
                workflowStates: linearIssueWorkflowStates,
                selectedIssueID: selectedLinearListIssueID,
                updatedAt: Date()
            )
        )
    }

    func refreshSelectedLinearListIssue(force: Bool = false) {
        guard let issueID = selectedLinearListIssueID else {
            selectedLinearListIssueTask?.cancel()
            selectedLinearListIssueTask = nil
            selectedLinearListIssueDetails = nil
            selectedLinearListIssueLoadState = .idle
            return
        }

        guard force || selectedLinearListIssueDetails?.identifier != issueID else { return }

        selectedLinearListIssueTask?.cancel()
        let hasStaleDetails = selectedLinearListIssueDetails?.identifier == issueID
        selectedLinearListIssueLoadState = hasStaleDetails ? .loaded : .loading
        if !hasStaleDetails {
            selectedLinearListIssueDetails = nil
        }

        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        selectedLinearListIssueTask = Task.detached(priority: .utility) {
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState =
                        self.selectedLinearListIssueDetails?.identifier == issueID
                        ? .loaded
                        : .failed("Unable to load issue details")
                }
            }
        }
    }

    func openSelectedLinearListIssue() {
        guard let url = selectedLinearListIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func updateSelectedLinearListIssueState(_ state: LinearWorkflowState) {
        guard let issueID = selectedLinearListIssueID else { return }
        selectedLinearListIssueTask?.cancel()
        selectedLinearListIssueLoadState = .updating(state.name)

        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        selectedLinearListIssueTask = Task.detached(priority: .userInitiated) {
            do {
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd)
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                    self.refreshLinearIssueList()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState = .failed("Unable to update issue state")
                }
            }
        }
    }

    func startSelectedLinearListIssueSession() {
        guard let issueID = selectedLinearListIssueID else { return }
        startLinearIssueSession(issueID)
    }

    func startLinearIssueSession(_ issueID: String) {
        linearIssueListLoadState = .starting(issueID)
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        Task.detached(priority: .userInitiated) {
            let errorMessage = Self.runBanyanWorktree(issueID: issueID, cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let errorMessage {
                    self.linearIssueListLoadState = .failed(errorMessage)
                } else {
                    self.sidebarMode = .sessions
                    self.linearIssueListLoadState = .loaded
                    self.runHistoryImport()
                }
            }
        }
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer(store: self)
        server.start()
        controlServer = server
    }

    /// A restored session's tmux pane is alive and inspectable long before its
    /// terminal client attaches, and `detectedAgentProvider` is not persisted — so
    /// gating the tick on `isProcessStarted` left every restored row showing the
    /// stale snapshot status and no provider icon until the user clicked it (which
    /// is what starts the client). Panes we have never started and are not restoring
    /// have nothing to inspect.
    nonisolated static func participatesInSupervisorTick(
        isProcessStarted: Bool,
        isRestored: Bool
    ) -> Bool {
        isProcessStarted || isRestored
    }

    nonisolated static func restoredStatus(snapshotStatus: SessionStatus, backingSessionExists: Bool) -> SessionStatus {
        if snapshotStatus == .closed {
            return .closed
        }
        return snapshotStatus
    }

    func startSupervisor() {
        installSupervisorLifecycleObserversIfNeeded()
        guard supervisorTimer == nil else { return }
        rescheduleSupervisor(runImmediately: true)
    }

    /// Adaptive cadence for the supervisor poll. Each tick spawns `/bin/ps` plus a
    /// `tmux list-panes`/`capture-pane` per started session, so a fixed 2s timer
    /// burned energy continuously even when backgrounded or idle. Per AGENTS.md the
    /// interval is adaptive to foreground/background, battery, thermal state, and
    /// session count. The supervisor still runs in the background (it drives the
    /// "agent needs input" notification) — just far less often.
    private var supervisorInterval: TimeInterval {
        var interval: TimeInterval = NSApp.isActive ? 2.0 : 6.0

        // Cost scales with the number of sessions inspected each tick.
        let startedSessions = sessions.reduce(into: 0) { count, session in
            if session.status != .closed && session.isProcessStarted { count += 1 }
        }
        if startedSessions > 8 {
            interval *= min(3.0, Double(startedSessions) / 8.0)
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            interval *= 2.0
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: interval *= 3.0
        case .fair: interval *= 1.5
        default: break
        }

        return min(interval, 30.0)
    }

    /// Re-evaluate the adaptive cadence and reinstall the timer only when it
    /// actually changed. `runImmediately` fires a tick now (used on launch and when
    /// the app regains focus, so the sidebar refreshes without waiting a full cycle).
    private func rescheduleSupervisor(runImmediately: Bool = false) {
        if runImmediately {
            runSupervisorTick()
        }

        let interval = supervisorInterval
        if supervisorTimer != nil, abs(interval - currentSupervisorInterval) < 0.01 {
            return
        }

        supervisorTimer?.invalidate()
        currentSupervisorInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.supervisorTimerFired()
            }
        }
        // Let macOS coalesce these wakeups with other timers to cut energy use.
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        supervisorTimer = timer
    }

    private func supervisorTimerFired() {
        runSupervisorTick()
        // Focus, thermal, power, or session count may have changed since the timer
        // was installed; adopt the new cadence for the next fire.
        rescheduleSupervisor()
    }

    private func installSupervisorLifecycleObserversIfNeeded() {
        guard supervisorLifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let onActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor(runImmediately: true) }
        }
        let onResign = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor() }
        }
        let onThermal = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor() }
        }
        let onPower = center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rescheduleSupervisor() }
        }
        supervisorLifecycleObservers = [onActive, onResign, onThermal, onPower]
    }

    @discardableResult
    func spawnSiblingSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        return spawn(cwd: cwd, command: "", parentSessionID: selectedSession?.parentSessionID)
    }

    /// The kind the project header's split "+" button spawns by default —
    /// whatever was last launched for this project, defaulting to a plain shell.
    func projectLaunch(for groupID: String) -> NewSessionLaunch {
        projectLaunchByGroup[groupID] ?? .zsh
    }

    @discardableResult
    func spawnSession(inProjectGroup groupID: String, launch: NewSessionLaunch) -> BanyanSession? {
        let groupSessions = visibleSessions.filter {
            $0.projectGroupID == groupID && !$0.isImportedHistory
        }
        guard let representative = groupSessions.first else { return nil }
        rememberProjectLaunch(launch, for: groupID)
        return spawn(cwd: representative.cwd, command: launch.command, parentSessionID: representative.parentSessionID)
    }

    private func rememberProjectLaunch(_ launch: NewSessionLaunch, for groupID: String) {
        guard projectLaunchByGroup[groupID] != launch else { return }
        projectLaunchByGroup[groupID] = launch
        UserDefaults.standard.set(
            projectLaunchByGroup.mapValues(\.rawValue),
            forKey: Self.projectLaunchDefaultsKey
        )
    }

    func openScratchTerminal() {
        if let window = scratchWindow, scratchSession != nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            requestScratchTerminalFocus()
            return
        }

        let cwd = selectedSession?.cwd ?? NSHomeDirectory()
        let id = uniqueID("scratch", avoidingLiveTmuxSessions: true)
        let session = BanyanSession(
            id: id,
            tmuxSessionName: TmuxBackend.sessionName(for: id),
            title: "Scratch",
            isTitlePinned: true,
            cwd: resolvedWorkingDirectory(cwd),
            command: "",
            tone: .neutral,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize
        )
        attachScratch(session)
        scratchSession = session

        let rootView = ScratchTerminalWindow(session: session)
            .environmentObject(self)
            .buttonStyle(.banyanDefault)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.scratchWindowIdentifier
        window.title = scratchWindowTitle(for: session)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]

        let delegate = ScratchTerminalWindowDelegate { [weak self] in
            Task { @MainActor in
                self?.scratchTerminalWindowWillClose()
            }
        }
        window.delegate = delegate
        scratchWindow = window
        scratchWindowDelegate = delegate

        positionScratchWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestScratchTerminalFocus()
    }

    func handleCloseCommand(in window: NSWindow?) {
        if isScratchTerminalWindow(window) {
            closeScratchTerminal()
            return
        }
        requestCloseSelectedSession()
    }

    func closeScratchTerminal() {
        closeScratchTerminal(closeWindow: true, killBackingSession: true)
    }

    private func scratchTerminalWindowWillClose() {
        closeScratchTerminal(closeWindow: false, killBackingSession: true)
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
        refreshSelectedContextInfo(force: true)
        saveSessions()
        return session
    }

    func respawn(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        // A closed session had its tmux backing killed, so reattaching would
        // rerun the original launch command from scratch. For codex/claude
        // sessions whose underlying agent session we resolved, rebuild the
        // command as a resume so prior context is restored instead of replayed.
        //
        // Sessions closed before the live transcript match ran — or persisted by
        // an older build — have no `agentSessionID`. Try to recover it from the
        // imported history now so those still resume instead of replaying.
        if session.agentSessionID == nil {
            recoverAgentSessionID(for: session)
        }
        if let resumeCommand = Self.reopenResumeCommand(
            status: session.status,
            provider: session.agentProvider,
            agentSessionID: session.agentSessionID,
            cwd: session.cwd
        ), session.command != resumeCommand {
            session.command = resumeCommand
        }
        session.reattachTerminalClient()
        selectedSessionID = id
        saveSessions()
    }

    /// Reopen a closed codex/claude session, but first write a trimmed copy of
    /// its transcript (stale tool output cleared) and resume that instead — so the
    /// continued session replays far fewer input tokens per turn. Falls back to a
    /// normal full `respawn` whenever there's nothing worth trimming or the
    /// transcript can't be prepared. The original transcript is never modified.
    func respawnTrimmed(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.agentSessionID == nil {
            recoverAgentSessionID(for: session)
        }
        guard session.status == .closed,
              let provider = session.agentProvider,
              [.codex, .claude].contains(provider),
              let sourceID = session.agentSessionID, !sourceID.isEmpty else {
            try? respawn(id: id)
            return
        }
        let cwd = session.cwd
        Task.detached(priority: .userInitiated) {
            let prepared = TranscriptResumePreparer.prepare(provider: provider, sourceID: sourceID, cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let prepared,
                      let command = AgentSessionHistoryImporter.resumeCommand(
                        provider: provider,
                        sourceID: prepared.newSourceID,
                        cwd: cwd
                      ),
                      let session = self.sessions.first(where: { $0.id == id }) else {
                    try? self.respawn(id: id)
                    return
                }
                session.command = command
                session.markAgentSessionID(prepared.newSourceID)
                session.reattachTerminalClient()
                self.selectedSessionID = id
                self.saveSessions()
            }
        }
    }

    /// Best-effort recovery of a closed session's underlying agent session UUID
    /// from the most recently imported transcript history, matched by provider,
    /// cwd, and creation/reset time. Used at reopen for sessions that never had
    /// `agentSessionID` resolved while live (closed too early, pinned title, or
    /// persisted by an older build) so they can still resume rather than replay.
    private func recoverAgentSessionID(for session: BanyanSession) {
        guard let match = Self.bestPromptTitleMatch(
            sessionCWD: session.cwd,
            sessionCreatedAt: session.createdAt,
            sessionResetAt: session.lastConversationResetAt,
            provider: session.agentProvider,
            in: latestImportedHistory
        ) else {
            return
        }
        session.markDetectedAgentProvider(match.provider)
        session.markAgentSessionID(match.sourceID)
    }

    /// Builds the resume command to use when reopening a closed coding-agent
    /// session, or nil when the original launch command should be kept (session
    /// still active, non-agent provider, resume unsupported, or the underlying
    /// agent session was never resolved).
    nonisolated static func reopenResumeCommand(
        status: SessionStatus,
        provider: CodingAgentProvider?,
        agentSessionID: String?,
        cwd: String
    ) -> String? {
        guard status == .closed,
              let provider,
              [.codex, .claude].contains(provider),
              let agentSessionID, !agentSessionID.isEmpty else {
            return nil
        }
        return AgentSessionHistoryImporter.resumeCommand(
            provider: provider,
            sourceID: agentSessionID,
            cwd: cwd
        )
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

    func refreshSelectedLinearIssue(force: Bool = false) {
        guard let session = selectedSession,
              session.status != .closed,
              let context = selectedContextInfo,
              let issueID = context.linearIssueID,
              !issueID.isEmpty else {
            selectedLinearIssueTask?.cancel()
            selectedLinearIssueTask = nil
            selectedLinearIssueStatusTask?.cancel()
            selectedLinearIssueStatusTask = nil
            stopSelectedLinearIssueStatusRefresh()
            selectedLinearIssueIdentifier = nil
            selectedLinearIssueDetails = nil
            selectedLinearIssueLoadState = .idle
            return
        }

        guard force
            || selectedLinearIssueIdentifier != issueID
            || selectedLinearIssueDetails?.identifier != issueID else {
            startSelectedLinearIssueStatusRefreshIfNeeded()
            return
        }

        selectedLinearIssueTask?.cancel()
        selectedLinearIssueStatusTask?.cancel()
        selectedLinearIssueStatusTask = nil
        selectedLinearIssueIdentifier = issueID
        let hasStaleDetails = selectedLinearIssueDetails?.identifier == issueID
        if !hasStaleDetails {
            selectedLinearIssueDetails = nil
        }
        selectedLinearIssueLoadState = hasStaleDetails ? .loaded : .loading

        let cwd = session.cwd
        let sessionID = session.id
        selectedLinearIssueTask = Task.detached(priority: .utility) {
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.selectedLinearIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearIssueLoadState = .loaded
                    self.startSelectedLinearIssueStatusRefreshIfNeeded()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    if self.selectedLinearIssueDetails?.identifier == issueID {
                        self.selectedLinearIssueLoadState = .loaded
                        self.startSelectedLinearIssueStatusRefreshIfNeeded()
                    } else {
                        self.selectedLinearIssueLoadState = .failed("Unable to load issue details")
                        self.stopSelectedLinearIssueStatusRefresh()
                    }
                }
            }
        }
    }

    func updateSelectedLinearIssueState(_ state: LinearWorkflowState) {
        guard let session = selectedSession,
              session.status != .closed,
              let issueID = selectedContextInfo?.linearIssueID else {
            return
        }

        selectedLinearIssueTask?.cancel()
        selectedLinearIssueIdentifier = issueID
        selectedLinearIssueLoadState = .updating(state.name)

        let cwd = session.cwd
        let sessionID = session.id
        selectedLinearIssueTask = Task.detached(priority: .userInitiated) {
            do {
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd)
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.applySelectedLinearIssueStatus(status)
                    self.selectedLinearIssueLoadState = .loaded
                    self.startSelectedLinearIssueStatusRefreshIfNeeded()
                    self.refreshSelectedContextInfo(force: true)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.selectedLinearIssueLoadState = .failed("Unable to update issue state")
                }
            }
        }
    }

    private func startSelectedLinearIssueStatusRefreshIfNeeded() {
        guard selectedLinearIssueStatusTimer == nil,
              selectedLinearIssueDetails != nil,
              selectedLinearIssueIdentifier != nil else {
            return
        }

        // Linear does not expose an app-local status change event here, so keep polling
        // scoped to the selected loaded issue and only fetch the lightweight status fields.
        selectedLinearIssueStatusTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSelectedLinearIssueStatus()
            }
        }
    }

    private func stopSelectedLinearIssueStatusRefresh() {
        selectedLinearIssueStatusTimer?.invalidate()
        selectedLinearIssueStatusTimer = nil
    }

    private func refreshSelectedLinearIssueStatus() {
        guard let session = selectedSession,
              session.status != .closed,
              let issueID = selectedLinearIssueIdentifier,
              selectedLinearIssueDetails?.identifier == issueID,
              selectedLinearIssueStatusTask == nil,
              selectedLinearIssueLoadState == .loaded else {
            return
        }

        let cwd = session.cwd
        let sessionID = session.id
        selectedLinearIssueStatusTask = Task.detached(priority: .utility) {
            do {
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.selectedLinearIssueStatusTask = nil
                    guard self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.applySelectedLinearIssueStatus(status)
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.selectedLinearIssueStatusTask = nil
                }
            }
        }
    }

    private func applySelectedLinearIssueStatus(_ status: LinearIssueStatusSnapshot) {
        guard status.identifier == selectedLinearIssueIdentifier,
              let issue = selectedLinearIssueDetails else {
            return
        }
        selectedLinearIssueDetails = issue.applying(status: status)
        mergeLinearWorkflowStates(status.workflowStates)
    }

    func openSelectedPullRequest() {
        if let url = selectedPullRequestURL {
            NSWorkspace.shared.open(url)
            return
        }
        resolveSelectedContextForOpenPullRequest()
    }

    func showSelectedPullRequestPreview() {
        isPullRequestPreviewPresented = true
        refreshSelectedPullRequestPreview()
    }

    func closePullRequestPreview() {
        selectedPullRequestTask?.cancel()
        selectedPullRequestTask = nil
        selectedPullRequestPreviewURL = nil
        selectedPullRequestDetails = nil
        selectedPullRequestLoadState = .idle
        isPullRequestPreviewPresented = false
    }

    func refreshSelectedPullRequestPreview(force: Bool = false) {
        guard isPullRequestPreviewPresented,
              let session = selectedSession,
              session.status != .closed else {
            closePullRequestPreview()
            return
        }

        if let url = selectedPullRequestURL {
            fetchSelectedPullRequestPreview(url: url, cwd: session.cwd, sessionID: session.id, force: force)
            return
        }

        resolveSelectedContextForPullRequestPreview()
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
        if session.isImportedHistory {
            session.terminate(markClosed: true)
        } else {
            session.killBackingSession()
        }
        if selectedSessionID == id {
            selectedSessionID = visibleSessions.first?.id
        }
        saveSessions()
        refreshImportedHistory()
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
            refreshImportedHistory()
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
        refreshImportedHistory()
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

    /// Resume an imported history item from a trimmed copy of its transcript so
    /// the first (and every) follow-up turn replays fewer input tokens. Falls back
    /// to `resumeImportedHistory` when there's nothing worth trimming or the
    /// transcript can't be prepared. The original transcript is never modified.
    func resumeImportedHistoryTrimmed(id: String, prompt: String? = nil) {
        guard let history = sessions.first(where: { $0.id == id && $0.isImportedHistory }),
              let provider = history.agentProvider,
              let sourceID = AgentSessionHistoryImporter.sourceID(fromImportedSessionID: history.id, provider: provider) else {
            _ = try? resumeImportedHistory(id: id, prompt: prompt)
            return
        }
        let cwd = history.cwd
        let title = history.displayTitle
        let transcriptURL = history.historyTranscriptURL
        Task.detached(priority: .userInitiated) {
            let prepared = TranscriptResumePreparer.prepare(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                transcriptURL: transcriptURL
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let prepared,
                      let command = AgentSessionHistoryImporter.resumeCommand(
                        provider: provider,
                        sourceID: prepared.newSourceID,
                        cwd: cwd,
                        prompt: prompt
                      ) else {
                    _ = try? self.resumeImportedHistory(id: id, prompt: prompt)
                    return
                }
                self.spawn(
                    id: "\(provider.rawValue)-\(String(prepared.newSourceID.prefix(8)))",
                    title: title,
                    cwd: cwd,
                    command: command,
                    tone: .blue
                )
            }
        }
    }

    func select(id: String) {
        selectedSessionID = id
    }

    func moveSidebarSessions(in groupID: String, from sourceOffsets: IndexSet, to destinationOffset: Int) {
        let groups = sessionSidebarGroups
        guard let group = groups.first(where: { $0.id == groupID }) else { return }

        let activeSidebarIDs = groups.flatMap { $0.items.map(\.id) }
        let groupSessionIDs = group.items.map(\.id)
        guard let reorderedIDs = Self.reorderedSidebarSessionIDs(
            activeSidebarIDs: activeSidebarIDs,
            groupSessionIDs: groupSessionIDs,
            sourceOffsets: sourceOffsets,
            destinationOffset: destinationOffset
        ), reorderedIDs != activeSidebarIDs else {
            return
        }

        applySidebarSessionOrder(activeSidebarIDs: activeSidebarIDs, reorderedIDs: reorderedIDs)
    }

    private func applySidebarSessionOrder(activeSidebarIDs: [String], reorderedIDs: [String]) {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let reorderedSidebarSessions = reorderedIDs.compactMap { sessionsByID[$0] }
        guard reorderedSidebarSessions.count == reorderedIDs.count else { return }

        let activeSidebarIDSet = Set(activeSidebarIDs)
        let activeSidebarIndices = sessions.indices.filter { activeSidebarIDSet.contains(sessions[$0].id) }
        guard activeSidebarIndices.count == reorderedSidebarSessions.count else { return }

        var nextSessions = sessions
        for (index, session) in zip(activeSidebarIndices, reorderedSidebarSessions) {
            nextSessions[index] = session
        }

        sessions = nextSessions
        sortMode = .manual
        saveSessions()
    }

    func moveSidebarSession(_ sourceID: String, to targetID: String, in groupID: String) {
        let groups = sessionSidebarGroups
        guard let group = groups.first(where: { $0.id == groupID }) else { return }

        let groupSessionIDs = group.items.map(\.id)
        let activeSidebarIDs = groups.flatMap { $0.items.map(\.id) }
        guard let reorderedIDs = Self.reorderedSidebarSessionIDs(
            activeSidebarIDs: activeSidebarIDs,
            groupSessionIDs: groupSessionIDs,
            sourceID: sourceID,
            targetID: targetID
        ), reorderedIDs != activeSidebarIDs else {
            return
        }

        applySidebarSessionOrder(activeSidebarIDs: activeSidebarIDs, reorderedIDs: reorderedIDs)
    }

    nonisolated static func reorderedSidebarSessionIDs(
        activeSidebarIDs: [String],
        groupSessionIDs: [String],
        sourceOffsets: IndexSet,
        destinationOffset: Int
    ) -> [String]? {
        guard !sourceOffsets.isEmpty,
              !groupSessionIDs.isEmpty,
              destinationOffset >= 0,
              destinationOffset <= groupSessionIDs.count,
              sourceOffsets.allSatisfy({ $0 >= 0 && $0 < groupSessionIDs.count })
        else {
            return nil
        }

        let sourceSet = Set(sourceOffsets)
        let movingIDs = sourceOffsets.sorted().map { groupSessionIDs[$0] }
        var remainingIDs = groupSessionIDs.enumerated().compactMap { index, id in
            sourceSet.contains(index) ? nil : id
        }
        let removedBeforeDestination = sourceOffsets.filter { $0 < destinationOffset }.count
        let insertionIndex = max(0, min(destinationOffset - removedBeforeDestination, remainingIDs.count))
        remainingIDs.insert(contentsOf: movingIDs, at: insertionIndex)

        let groupIDSet = Set(groupSessionIDs)
        guard groupIDSet.count == groupSessionIDs.count,
              groupIDSet.isSubset(of: Set(activeSidebarIDs)) else {
            return nil
        }

        var reorderedGroupIterator = remainingIDs.makeIterator()
        return activeSidebarIDs.map { id in
            if groupIDSet.contains(id) {
                return reorderedGroupIterator.next() ?? id
            }
            return id
        }
    }

    nonisolated static func reorderedSidebarSessionIDs(
        activeSidebarIDs: [String],
        groupSessionIDs: [String],
        sourceID: String,
        targetID: String
    ) -> [String]? {
        guard let sourceIndex = groupSessionIDs.firstIndex(of: sourceID),
              let targetIndex = groupSessionIDs.firstIndex(of: targetID),
              sourceIndex != targetIndex else {
            return nil
        }

        let destinationOffset = sourceIndex < targetIndex ? targetIndex + 1 : targetIndex
        return reorderedSidebarSessionIDs(
            activeSidebarIDs: activeSidebarIDs,
            groupSessionIDs: groupSessionIDs,
            sourceOffsets: IndexSet(integer: sourceIndex),
            destinationOffset: destinationOffset
        )
    }

    func selectNextSession() {
        selectAdjacentSession(direction: .next)
    }

    func selectPreviousSession() {
        selectAdjacentSession(direction: .previous)
    }

    func selectNextWorkableSession() {
        guard let id = SessionSelectionNavigator.nextMatchingID(
            in: sidebarSessions.map(\.id),
            selectedID: selectedSessionID,
            isMatch: isWorkableSession
        ) else {
            return
        }
        selectedSessionID = id
    }

    var hasWorkableSession: Bool {
        sidebarSessions.contains { isWorkableSession($0.id) }
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

    func dispatchHandoff(id: String) {
        guard let session = sessions.first(where: { $0.id == id }),
              session.canDispatchHandoff,
              !pendingHandoffJobs.contains(where: { $0.sessionID == id }) else {
            return
        }

        let job = HandoffJob(
            id: id,
            sessionID: id,
            title: session.displayTitle,
            cwd: session.cwd,
            startedAt: Date()
        )

        do {
            try close(id: id)
        } catch {
            return
        }

        pendingHandoffJobs.append(job)
        Task.detached(priority: .utility) {
            let result = runHandoffDispatch(cwd: job.cwd)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingHandoffJobs.removeAll { $0.id == job.id }
                if case .failure = result {
                    try? self.respawn(id: job.sessionID)
                }
            }
        }
    }

    func isHandoffPending(for sessionID: String) -> Bool {
        pendingHandoffJobs.contains { $0.sessionID == sessionID }
    }

    var selectedLinearIssueURL: URL? {
        if let value = selectedContextInfo?.linearIssueURL, let url = URL(string: value) {
            return url
        }
        return nil
    }

    var selectedLinearListIssueURL: URL? {
        if let value = selectedLinearListIssueDetails?.url, let url = URL(string: value) {
            return url
        }
        if let value = linearIssues.first(where: { $0.identifier == selectedLinearListIssueID })?.url,
           let url = URL(string: value) {
            return url
        }
        guard let selectedLinearListIssueID else { return nil }
        return URL(string: LinearIssueReference.issueURL(for: selectedLinearListIssueID))
    }

    var selectedLinearListIssueContext: SessionContextInfo? {
        guard let issueID = selectedLinearListIssueID else { return nil }
        let title = selectedLinearListIssueDetails?.title
            ?? linearIssues.first(where: { $0.identifier == issueID })?.title
        let url = selectedLinearListIssueURL?.absoluteString
        return SessionContextInfo(
            sessionID: "linear-list",
            signature: issueID,
            linearIssueID: issueID,
            linearIssueTitle: title,
            linearIssueURL: url,
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil
        )
    }

    var selectedPullRequestURL: URL? {
        let value = selectedPullRequestDetails?.url ?? selectedContextInfo?.pullRequestURL
        guard let value else { return nil }
        return URL(string: value)
    }

    var canAttemptSelectedPullRequestPreview: Bool {
        guard let selectedSession else { return false }
        return selectedSession.status != .closed
    }

    var selectedPullRequestPreviewContext: SessionContextInfo? {
        if let selectedContextInfo {
            return selectedContextInfo
        }
        guard let selectedSession else { return nil }
        return SessionContextInfo(
            sessionID: selectedSession.id,
            signature: selectedSession.id,
            linearIssueID: nil,
            linearIssueTitle: nil,
            linearIssueURL: nil,
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil
        )
    }

    func requestClose(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if hasActiveChildren(id) || Self.isOngoingCodexOrClaudeSession(status: session.status, provider: session.agentProvider) {
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

    nonisolated static func isOngoingCodexOrClaudeSession(
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> Bool {
        guard provider == .codex || provider == .claude else { return false }
        return ![.completed, .failed, .closed].contains(status)
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
            PerformanceTelemetry.shared.noteSessionFirstOutput(sessionID: session.id)
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

    private func attachScratch(_ session: BanyanSession) {
        session.onDidChange = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.scratchSession === session else { return }
                self.scratchWindow?.title = self.scratchWindowTitle(for: session)
            }
        }
        session.onOutput = { [weak session] _ in
            guard let session else { return }
            PerformanceTelemetry.shared.noteSessionFirstOutput(sessionID: session.id)
        }
        session.onStatusSignal = nil
        session.onProcessExit = { [weak self, weak session] _ in
            guard let self, let session, self.scratchSession === session else { return }
            if self.tmuxBackend.hasSession(named: session.tmuxSessionName) {
                session.detachTerminalClient()
            } else {
                self.closeScratchTerminal(closeWindow: true, killBackingSession: false)
            }
        }
    }

    private func closeScratchTerminal(closeWindow: Bool, killBackingSession: Bool) {
        guard !isClosingScratchTerminal else { return }
        guard scratchSession != nil || scratchWindow != nil else { return }
        isClosingScratchTerminal = true

        let session = scratchSession
        let window = scratchWindow
        scratchSession = nil
        scratchWindow = nil
        scratchWindowDelegate = nil

        if killBackingSession {
            session?.killBackingSession()
        } else {
            session?.terminate(markClosed: true)
        }

        if closeWindow {
            window?.delegate = nil
            window?.close()
        }

        isClosingScratchTerminal = false
    }

    private func requestScratchTerminalFocus() {
        scratchTerminalFocusRequestID = UUID()
    }

    private func requestTerminalFocus() {
        terminalFocusRequestID = UUID()
    }

    private func applyAppearance() {
        sessions.forEach {
            $0.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
        }
        scratchSession?.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
    }

    private func saveSessions() {
        let snapshots = sessions.filter { !$0.isImportedHistory }.map {
            SessionSnapshot(
                id: $0.id,
                tmuxSessionName: $0.tmuxSessionName,
                title: $0.title,
                titleURL: $0.titleURL,
                titleURLWasAutoDetected: $0.titleURLWasAutoDetected,
                reportedTitle: $0.reportedTitle,
                generatedTitle: $0.generatedTitle,
                isTitlePinned: $0.isTitlePinned,
                cwd: $0.cwd,
                command: $0.command,
                status: $0.status,
                tone: $0.tone,
                parentSessionID: $0.parentSessionID,
                agentSessionID: $0.agentSessionID,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt
            )
        }
        // Supervisor ticks call this every cycle; skip the SQLite rewrite entirely
        // when nothing changed. This was the dominant main-thread stall behind the
        // "Application Not Responding" freezes.
        guard snapshots != lastSavedSessionSnapshots else { return }
        lastSavedSessionSnapshots = snapshots
        let persistence = persistence
        // Perform the actual open+migrate+DELETE+re-insert off the main thread so a
        // real change never blocks the UI; the serial queue preserves write order.
        sessionPersistenceQueue.async {
            persistence.save(snapshots)
        }
    }

    private func saveWorkspace() {
        workspaceSaveTask?.cancel()
        persistence.saveWorkspace(workspaceSnapshot())
    }

    private func saveWorkspaceSoon() {
        workspaceSaveTask?.cancel()
        let persistence = persistence
        let snapshot = workspaceSnapshot()
        workspaceSaveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            persistence.saveWorkspace(snapshot)
        }
    }

    private func workspaceSnapshot() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            selectedSessionID: selectedSessionID,
            sortMode: sortMode,
            terminalTheme: terminalTheme,
            terminalFontFamily: terminalFontFamily,
            terminalFontSize: terminalFontSize
        )
    }

    private func runHistoryImport(spawnDefaultIfEmpty: Bool = false) {
        guard !isHistoryImportRunning else {
            isHistoryImportPending = true
            return
        }
        isHistoryImportRunning = true
        Task.detached(priority: .utility) {
            let imported = AgentSessionHistoryImporter.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyImportedHistory(imported)
                self.isHistoryImportRunning = false
                let shouldRunPendingImport = self.isHistoryImportPending
                self.isHistoryImportPending = false
                if spawnDefaultIfEmpty, self.visibleSessions.isEmpty {
                    self.spawn(cwd: NSHomeDirectory())
                }
                if shouldRunPendingImport {
                    self.runHistoryImport()
                }
            }
        }
    }

    private func applyImportedHistory(_ imported: [ImportedAgentSession]) {
        latestImportedHistory = imported
        if sessions.contains(where: \.isImportedHistory) {
            sessions.removeAll { $0.isImportedHistory }
        }
        refreshLiveAgentTitles(from: imported)

        if let selectedSessionID, !sidebarSessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = sidebarSessions.first?.id
        } else if selectedSessionID == nil {
            selectedSessionID = sidebarSessions.first?.id
        }
    }

    /// Whether a live session participates in the transcript-matching pass that
    /// resolves both its display title and `agentSessionID`.
    ///
    /// Pinned-title sessions (e.g. Linear worktrees launched with an explicit
    /// "ENG-1234 …" title) are intentionally included. Excluding them left the
    /// pass resolving no `agentSessionID`, so reopening a closed one replayed the
    /// initial prompt instead of resuming. The title updates in the caller are
    /// individually guarded by `hasUsefulPinnedTitle`, so a user's pinned title is
    /// still never overwritten.
    nonisolated static func participatesInLiveAgentMatch(
        isImportedHistory: Bool,
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> Bool {
        guard !isImportedHistory, status != .closed else { return false }
        guard let provider else { return true }
        return [.claude, .codex].contains(provider)
    }

    private func refreshLiveAgentTitles(from imported: [ImportedAgentSession]) {
        let candidates = imported.filter { [.claude, .codex].contains($0.provider) }
        guard !candidates.isEmpty else { return }

        let liveSessions = sessions.filter {
            Self.participatesInLiveAgentMatch(
                isImportedHistory: $0.isImportedHistory,
                status: $0.status,
                provider: $0.agentProvider
            )
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
            session.markAgentSessionID(match.sourceID)
            // Use the current-segment title so a freshly cleared conversation
            // (segment title nil until the next prompt) does not get its
            // pre-/clear first-prompt title resurrected onto the live session.
            if let segmentTitle = match.segmentPromptTitle {
                session.markFirstPromptTitle(segmentTitle)
            } else if match.segmentWasCleared {
                // The transcript shows a /clear or /new with no prompt since.
                // Actively drop the stale title even when the keystroke path
                // missed the reset (autocomplete, paste, unfocused terminal,
                // or a /clear issued while Banyan was closed).
                session.noteConversationResetFromTranscript()
            }
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
            guard Self.participatesInSupervisorTick(
                isProcessStarted: session.isProcessStarted,
                isRestored: session.isRestored
            ) else {
                return nil
            }
            return SupervisorSessionInput(
                id: session.id,
                tmuxSessionName: session.tmuxSessionName,
                command: session.command,
                status: session.status,
                isAwaitingAttach: !session.isProcessStarted
            )
        }
        guard !inputs.isEmpty else { return }

        isSupervisorTickRunning = true

        Task.detached(priority: .utility) { [weak self] in
            // Time the whole tick: `ps` snapshot + per-session tmux inspection. This
            // is the app's steady-state energy cost, previously untracked and so
            // invisible in `banyanctl perf report`.
            let tickStartedAt = DispatchTime.now()
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
                // A restored session whose tmux session is gone is not dead — clicking
                // it recreates the backing session. Only a session we have actually
                // attached to may be closed out from under us.
                if result.status == .closed && input.isAwaitingAttach {
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

            PerformanceTelemetry.shared.recordDuration(
                "supervisor.tick",
                durationMS: PerformanceTelemetry.elapsedMS(since: tickStartedAt),
                detail: "sessions=\(inputs.count)"
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applySupervisorResults(results)
                self.isSupervisorTickRunning = false
                self.saveSessions()
                self.refreshSelectedContextInfoIfStale()
            }
        }
    }

    /// Returns a non-expired cached context for `input`, reidentified to the current
    /// session/signature. Lets user-triggered PR flows reuse a recent result instead
    /// of always re-spawning `linear`/`gh`.
    private func freshCachedSelectedContext(for input: SessionContextLookupInput) -> SessionContextInfo? {
        let key = SessionContextResolver.cacheKey(for: input)
        guard let cached = selectedContextCache[key],
              Date().timeIntervalSince(cached.at) < selectedContextCacheTTL else {
            return nil
        }
        return cached.info.reidentified(sessionID: input.sessionID, signature: input.signature)
    }

    private func storeSelectedContext(_ info: SessionContextInfo, key: String) {
        selectedContextCache[key] = (info, Date())
        // Distinct keys are bounded by active projects/issues, but cap defensively.
        if selectedContextCache.count > 64,
           let oldest = selectedContextCache.min(by: { $0.value.at < $1.value.at })?.key {
            selectedContextCache.removeValue(forKey: oldest)
        }
    }

    private func refreshSelectedContextInfo(force: Bool = false) {
        guard let input = selectedContextLookupInput() else {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextSignature = nil
            selectedContextInfo = nil
            return
        }

        guard force || input.signature != selectedContextSignature else { return }

        selectedContextSignature = input.signature

        let cacheKey = SessionContextResolver.cacheKey(for: input)

        // Serve a fresh cached result instantly; this is the common case now that
        // the cache key ignores free-text title churn, so no subprocess is spawned.
        if let cached = selectedContextCache[cacheKey],
           Date().timeIntervalSince(cached.at) < selectedContextCacheTTL {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextInfo = cached.info.reidentified(
                sessionID: input.sessionID,
                signature: input.signature
            )
            selectedContextResolvedAt = Date()
            return
        }

        // Cache miss/expiry: show the subprocess-free fast fields immediately so the
        // titlebar isn't blank, then enrich from git/linear/gh in the background.
        selectedContextInfo = SessionContextResolver.resolveFast(input: input)
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .utility) {
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            PerformanceTelemetry.shared.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature)"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: cacheKey)
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
            }
        }
    }

    private func resolveSelectedContextForOpenPullRequest() {
        guard let input = selectedContextLookupInput() else { return }
        // Repeat clicks / already-resolved PRs: open straight from the fresh cache so
        // the action is instant and spawns no subprocess. Fall through to a fresh
        // resolve when the cache lacks a PR, so a newly-created PR is still discovered.
        if let cached = freshCachedSelectedContext(for: input),
           let value = cached.pullRequestURL, let url = URL(string: value) {
            selectedContextSignature = input.signature
            selectedContextInfo = cached
            selectedContextResolvedAt = Date()
            NSWorkspace.shared.open(url)
            return
        }
        selectedContextSignature = input.signature
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .userInitiated) {
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            PerformanceTelemetry.shared.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature) open_pr"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: SessionContextResolver.cacheKey(for: input))
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
                guard let value = info.pullRequestURL, let url = URL(string: value) else { return }
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func resolveSelectedContextForPullRequestPreview() {
        guard let input = selectedContextLookupInput() else {
            selectedPullRequestLoadState = .failed("No active session")
            return
        }

        selectedPullRequestLoadState = .loading
        selectedContextSignature = input.signature
        // Drive the preview from the fresh cache when it already knows the PR, avoiding
        // a redundant `linear`/`gh` resolve. A cache miss (or cached-but-no-PR) still
        // resolves fresh below so a just-created PR is picked up.
        if let cached = freshCachedSelectedContext(for: input),
           cached.pullRequestURL != nil {
            selectedContextTask?.cancel()
            selectedContextTask = nil
            selectedContextInfo = cached
            selectedContextResolvedAt = Date()
            if let session = selectedSession {
                let url = cached.pullRequestURL.flatMap(URL.init(string:))
                fetchSelectedPullRequestPreview(
                    url: url,
                    cwd: session.cwd,
                    sessionID: session.id,
                    force: true
                )
            } else {
                selectedPullRequestLoadState = .failed("No active session")
            }
            return
        }
        selectedContextTask?.cancel()
        selectedContextTask = Task.detached(priority: .userInitiated) {
            let startedAt = DispatchTime.now()
            let info = await SessionContextResolver.resolve(input: input) {
                Task.isCancelled
            }
            PerformanceTelemetry.shared.recordDuration(
                "selected_context.resolve",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: input.sessionID,
                detail: "signature=\(input.signature) pr_preview"
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.storeSelectedContext(info, key: SessionContextResolver.cacheKey(for: input))
                guard self.selectedSessionID == input.sessionID,
                      self.selectedContextSignature == input.signature,
                      self.isPullRequestPreviewPresented else {
                    return
                }
                self.selectedContextInfo = info
                self.selectedContextResolvedAt = Date()
                guard let session = self.selectedSession else {
                    self.selectedPullRequestLoadState = .failed("No active session")
                    return
                }
                let url = info.pullRequestURL.flatMap(URL.init(string:))
                self.fetchSelectedPullRequestPreview(
                    url: url,
                    cwd: session.cwd,
                    sessionID: session.id,
                    force: true
                )
            }
        }
    }

    private func fetchSelectedPullRequestPreview(
        url: URL?,
        cwd: String,
        sessionID: String,
        force: Bool
    ) {
        guard force || selectedPullRequestPreviewURL != url || selectedPullRequestDetails == nil else {
            selectedPullRequestLoadState = .loaded
            return
        }

        selectedPullRequestTask?.cancel()
        selectedPullRequestPreviewURL = url
        selectedPullRequestDetails = nil
        selectedPullRequestLoadState = .loading

        selectedPullRequestTask = Task.detached(priority: .utility) {
            do {
                let details = try await GitHubPullRequestClient.fetchPullRequest(url: url, cwd: cwd)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.isPullRequestPreviewPresented,
                          self.selectedPullRequestPreviewURL == url else {
                        return
                    }
                    self.selectedPullRequestTask = nil
                    self.selectedPullRequestDetails = details
                    self.selectedPullRequestPreviewURL = URL(string: details.url)
                    self.selectedPullRequestLoadState = .loaded
                }
            } catch {
                let message = GitHubPullRequestClient.message(for: error)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.isPullRequestPreviewPresented,
                          self.selectedPullRequestPreviewURL == url else {
                        return
                    }
                    self.selectedPullRequestTask = nil
                    self.selectedPullRequestLoadState = .failed(message)
                }
            }
        }
    }

    private func selectedContextLookupInput() -> SessionContextLookupInput? {
        guard let session = selectedSession, session.status != .closed else {
            return nil
        }
        return SessionContextLookupInput(
            sessionID: session.id,
            cwd: session.cwd,
            title: session.title,
            titleURL: session.titleURL,
            displayTitle: session.displayTitle
        )
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

    private func isScratchTerminalWindow(_ window: NSWindow?) -> Bool {
        window?.identifier == Self.scratchWindowIdentifier
    }

    private func scratchWindowTitle(for session: BanyanSession) -> String {
        "Scratch - \(PathDisplayName.make(path: session.cwd))"
    }

    private func positionScratchWindow(_ window: NSWindow) {
        let fallbackScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let anchorFrame = anchorWindow?.frame ?? fallbackScreen
        let visibleFrame = anchorWindow?.screen?.visibleFrame ?? fallbackScreen

        let width = min(max(anchorFrame.width * 0.72, 720), visibleFrame.width - 80)
        let height = min(max(anchorFrame.height * 0.52, 420), visibleFrame.height - 80)
        let originX = min(max(anchorFrame.midX - width / 2, visibleFrame.minX + 40), visibleFrame.maxX - width - 40)
        let originY = min(max(anchorFrame.midY - height / 2, visibleFrame.minY + 40), visibleFrame.maxY - height - 40)
        window.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: false)
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

    nonisolated private static func runBanyanWorktree(issueID: String, cwd: String) -> String? {
        let executablePath = "\(NSHomeDirectory())/bin/banyan-worktree"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "Missing ~/bin/banyan-worktree"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--banyan", issueID]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = AppProcessEnvironment.make(pathAdditions: [
            "\(NSHomeDirectory())/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/go/bin",
            "\(NSHomeDirectory())/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return "Unable to start banyan-worktree"
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "banyan-worktree failed" : message
        }
        return nil
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

    private func isWorkableSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return !session.isImportedHistory
            && session.status != .closed
            && [.asking, .needInput].contains(session.status)
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

private func runHandoffDispatch(cwd: String) -> Result<Void, HandoffDispatchError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["\(NSHomeDirectory())/bin/handoff", "dispatch"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = AppProcessEnvironment.make()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return .failure(.commandUnavailable)
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return .failure(.failed(process.terminationStatus))
    }
    return .success(())
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
