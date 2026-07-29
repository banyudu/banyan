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

private struct PendingLinearDescriptionUpdate {
    let issueID: String
    let oldDescription: String?
    let newDescription: String
}

private enum HandoffDispatchError: Error {
    case commandUnavailable
    case failed(Int32)
}

@MainActor
final class SessionStore: ObservableObject {
    private static let scratchWindowIdentifier = NSUserInterfaceItemIdentifier("banyan.scratch-terminal")

    @Published private(set) var sessions: [BanyanSession] = []
    @Published private(set) var terminalFocusRequestID = UUID()
    @Published private(set) var commandPaletteRequestID = UUID()
    @Published private(set) var scratchTerminalFocusRequestID = UUID()
    @Published private(set) var scratchSession: BanyanSession?
    @Published private(set) var selectedContextInfo: SessionContextInfo? {
        didSet {
            refreshSelectedLinearIssue()
            refreshSelectedGitHubIssue()
        }
    }
    @Published private(set) var selectedLinearIssueDetails: LinearIssueDetails?
    @Published private(set) var selectedLinearIssueLoadState: LinearIssueLoadState = .idle
    @Published private(set) var selectedGitHubIssueDetails: GitHubIssueDetails?
    @Published private(set) var selectedGitHubIssueLoadState: GitHubIssueLoadState = .idle
    @Published var isPullRequestPreviewPresented = false
    @Published private(set) var selectedPullRequestDetails: GitHubPullRequestDetails?
    @Published private(set) var selectedPullRequestLoadState: GitHubPullRequestLoadState = .idle
    @Published var sidebarMode: SidebarMode = .sessions {
        didSet {
            if sidebarMode == .linear {
                refreshLinearIssueListOnEnter()
            }
        }
    }
    @Published private(set) var linearIssues: [LinearIssueSummary] = []
    @Published private(set) var linearIssueWorkflowStates: [LinearWorkflowState] = []
    @Published private(set) var linearIssueListLoadState: LinearIssueListLoadState = .idle
    @Published private(set) var isLinearIssueListRefreshing = false
    @Published private(set) var linearIssueNavigationIDs: [String]?
    @Published var selectedLinearListIssueID: String? {
        didSet {
            refreshSelectedLinearListIssue()
        }
    }
    @Published private(set) var selectedLinearListIssueDetails: LinearIssueDetails?
    @Published private(set) var selectedLinearListIssueLoadState: LinearIssueLoadState = .idle
    @Published private(set) var linearFilterFocusRequestID = UUID()
    @Published private(set) var pendingHandoffJobs: [HandoffJob] = []
    @Published var handoffNotice: String?
    @Published var addSessionDraft: AddSessionDraft?
    private(set) var sessionSwitchRequestedAt: DispatchTime?
    let selection = SessionSelection()
    @Published var selectedSessionID: String? {
        didSet {
            selection.syncFromStore(selectedSessionID)
            if oldValue != selectedSessionID {
                sessionSwitchRequestedAt = .now()
                telemetry.beginSessionSwitch(
                    from: oldValue,
                    to: selectedSessionID,
                    visibleSessionCount: visibleSessions.count
                )
                if isPullRequestPreviewPresented {
                    closePullRequestPreview()
                }
            }
            saveWorkspaceSoon()
            requestTerminalFocus()
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
    private let persistence: any SessionStorePersistenceBackend
    /// Serial queue for the SQLite session write, keeping the full-table rewrite off
    /// the main thread. Serial + ordered so concurrent saves can't collide on the
    /// `BEGIN IMMEDIATE` transaction.
    private let sessionPersistenceQueue = DispatchQueue(label: "com.banyan.session-persistence", qos: .utility)
    /// Last snapshot set written to disk; lets `saveSessions()` skip the frequent
    /// no-op saves (e.g. every supervisor tick) that re-serialized unchanged state.
    private var lastSavedSessionSnapshots: [SessionSnapshot]?
    private let detector: AgentStateDetector
    private let tmuxBackend: any TmuxSessionStoreBackend
    private let sessionBackend: any TmuxClientBackend
    private let processTable: any ProcessTableProvider
    private let historyBackend: any SessionHistoryBackend
    private let attentionNotifier: AttentionNotifier
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
    @Published private(set) var pendingRespawnRecoveryIDs = Set<String>()
    @Published private(set) var historyResumeErrors: [String: String] = [:]
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
    private var selectedGitHubIssueTask: Task<Void, Never>?
    private var selectedGitHubIssueURL: URL?
    private var selectedLinearIssueStatusTask: Task<Void, Never>?
    private var selectedLinearIssueStatusTimer: Timer?
    private var selectedLinearIssueIdentifier: String?
    private var pendingSelectedLinearDescriptionUpdate: PendingLinearDescriptionUpdate?
    private var selectedPullRequestTask: Task<Void, Never>?
    private var selectedPullRequestPreviewURL: URL?
    private var didLoadCachedLinearIssues = false
    private var linearIssueListTask: Task<Void, Never>?
    private var linearIssueListRefreshTimer: Timer?
    private static let linearIssueListRefreshInterval: TimeInterval = 30 * 60
    private static let linearIssueListLoadTimeout: TimeInterval = 45
    private var selectedLinearListIssueTask: Task<Void, Never>?
    private var pendingSelectedLinearListDescriptionUpdate: PendingLinearDescriptionUpdate?
    /// Recently loaded issue details stay available while the user moves
    /// through the Linear list. Re-selecting an issue can render this stale
    /// snapshot immediately while the network refresh runs in the background.
    private var linearIssueDetailsCache: [String: LinearIssueDetails] = [:]
    private var workspaceSaveTask: Task<Void, Never>?
    private var scratchWindow: NSWindow?
    private var scratchWindowDelegate: ScratchTerminalWindowDelegate?
    private var isClosingScratchTerminal = false
    let host: HostRuntimeContext
    let telemetry: PerformanceTelemetry
    private var homeDirectory: String { host.homeDirectory.path }
    private var environment: [String: String] { host.environment }
    private var currentDirectory: String { host.currentDirectory }

    init(
        persistence: any SessionStorePersistenceBackend,
        tmuxBackend: any TmuxSessionStoreBackend,
        sessionBackend: any TmuxClientBackend,
        processTable: any ProcessTableProvider,
        historyBackend: any SessionHistoryBackend,
        detector: AgentStateDetector,
        host: HostRuntimeContext,
        telemetry: PerformanceTelemetry,
        attentionNotifier: AttentionNotifier
    ) {
        self.persistence = persistence
        self.tmuxBackend = tmuxBackend
        self.sessionBackend = sessionBackend
        self.processTable = processTable
        self.historyBackend = historyBackend
        self.detector = detector
        self.host = host
        self.telemetry = telemetry
        self.attentionNotifier = attentionNotifier
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

        selection.bind(to: self)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSessionSaves()
        }

        installLinearIssueListRefreshTimer()
    }

    /// Blocks until the serial session-persistence queue drains. Safe to call from a
    /// non-isolated context (only touches the immutable, Sendable queue).
    nonisolated private func flushPendingSessionSaves() {
        sessionPersistenceQueue.sync {}
    }

    var visibleSessions: [BanyanSession] {
        let items = sessions.map {
            SessionVisibilityItem(
                id: $0.id,
                status: $0.status,
                updatedAt: $0.updatedAt,
                displayTitle: $0.displayTitle
            )
        }
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionVisibilityPolicy.visibleIDs(from: items, sortMode: sortMode).compactMap { sessionsByID[$0] }
    }

    var recoverySessions: [BanyanSession] {
        sessions.filter { $0.needsRecovery && !$0.isImportedHistory }
    }

    var sessionSidebarGroups: [SidebarSessionGroup] {
        let active = visibleSessions.filter { !$0.isImportedHistory }
        let candidates = active.map {
            SessionSidebarCandidate(
                id: $0.id,
                groupID: $0.projectGroupID,
                groupTitle: $0.projectGroupTitle,
                parentSessionID: $0.parentSessionID
            )
        }
        let sessionsByID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionSidebarGroupingPolicy.groups(for: candidates).map { group in
            SidebarSessionGroup(
                id: group.id,
                title: group.title,
                items: group.rows.compactMap { row in
                    guard let session = sessionsByID[row.id] else { return nil }
                    return SidebarSessionItem(session: session, depth: row.depth)
                }
            )
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

    var hasLocalHistorySessions: Bool {
        sessions.contains { session in
            SessionHistoryPolicy.isLocalHistorySession(
                status: session.status,
                isImportedHistory: session.isImportedHistory,
                provider: session.agentProvider,
                hasIssueLink: session.titleLinkLabel != nil
            )
        }
    }

    private var sidebarHistoryItems: [SidebarSessionItem] {
        let candidates = sessions
            .filter { session in
                SessionHistoryPolicy.isLocalHistorySession(
                    status: session.status,
                    isImportedHistory: session.isImportedHistory,
                    provider: session.agentProvider,
                    hasIssueLink: session.titleLinkLabel != nil
                )
            }
            .map { session in
                SessionHistorySidebarCandidate(
                    id: session.id,
                        projectName: session.projectName,
                        displayTitle: session.displayTitle,
                    issueID: session.titleLinkLabel,
                    updatedAt: session.updatedAt
                )
            }
        let sessionsByID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return SessionHistoryPresentation.sidebarEntries(
            from: candidates,
            query: historyFilterText
        ).compactMap { entry in
            guard let session = sessionsByID[entry.id] else { return nil }
            return SidebarSessionItem(session: session, depth: 0, titleOverride: entry.title)
        }
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
        return SessionLifecyclePolicy.isOngoingCodingAgentSession(
            status: session.status,
            provider: session.agentProvider
        )
    }

    func loadPersistedSessionsIfNeeded() {
        guard !didLoadPersistedSessions else { return }
        didLoadPersistedSessions = true
        let snapshots = persistence.load()
        let liveTmuxSessionNames = Set(tmuxBackend.listBanyanSessions())
        var loadedTmuxSessionNames = Set<String>()
        // Hundreds of historical rows often share a cwd. Repository context is a
        // property of that directory, not of an individual session, so resolve it
        // once during this restore pass instead of spawning the same local git
        // commands for every row.
        var displayContextsByCWD: [String: SessionProjectContext] = [:]
        for snapshot in snapshots {
            let restorationPlan = SessionRestorationPolicy.plan(
                for: snapshot,
                liveTmuxSessionNames: liveTmuxSessionNames
            )
            let displayContext: SessionProjectContext
            if let cached = displayContextsByCWD[snapshot.cwd] {
                displayContext = cached
            } else {
                let resolved = SessionDisplayLabel.context(
                    cwd: snapshot.cwd,
                    homeDirectory: homeDirectory,
                    environment: environment
                )
                displayContextsByCWD[snapshot.cwd] = resolved
                displayContext = resolved
            }
            let session = BanyanSession(
                id: uniqueID(snapshot.id, avoidingLiveTmuxSessions: false),
                tmuxSessionName: restorationPlan.tmuxSessionName,
                title: SessionRestorationPolicy.restoredTitle(
                    for: snapshot,
                    homeDirectory: homeDirectory
                ),
                titleURL: snapshot.titleURL,
                titleURLWasAutoDetected: snapshot.titleURLWasAutoDetected,
                generatedTitle: snapshot.generatedTitle,
                isTitlePinned: snapshot.isTitlePinned,
                cwd: snapshot.cwd,
                command: snapshot.command,
                status: restorationPlan.status,
                tone: snapshot.tone,
                parentSessionID: snapshot.parentSessionID,
                agentSessionID: snapshot.agentSessionID,
                createdAt: snapshot.createdAt,
                updatedAt: snapshot.updatedAt,
                isRestored: true,
                needsRecovery: restorationPlan.needsRecovery,
                displayContext: displayContext,
                theme: terminalTheme,
                fontFamily: terminalFontFamily,
                fontSize: terminalFontSize,
                tmuxBackend: sessionBackend,
                telemetry: telemetry,
                host: host
            )
            session.reportedTitle = snapshot.reportedTitle
            attach(session)
            sessions.append(session)
            if session.status != .closed {
                loadedTmuxSessionNames.insert(session.tmuxSessionName)
            }
        }
        for tmuxSessionName in SessionHistoryPresentation.staleTmuxSessionNames(
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
        // A machine restart kills the dedicated tmux server, but not this
        // persisted metadata. Recreate all missing sessions automatically so
        // agents resume in the background as soon as Banyan launches.
        recoverAll(selectRecoveredSession: false)
        refreshSelectedContextInfo(force: true)
        saveSessions()
    }

    func refreshImportedHistory(spawnDefaultIfEmpty: Bool = false) {
        runHistoryImport(spawnDefaultIfEmpty: spawnDefaultIfEmpty)
    }

    /// Shows the cached list immediately, then refreshes it in the background
    /// whenever the Linear tab becomes visible.
    func refreshLinearIssueListOnEnter() {
        refreshLinearIssueList()
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
        isLinearIssueListRefreshing = true
        let cwd = selectedSession?.cwd ?? homeDirectory
        let deadline = Date().addingTimeInterval(Self.linearIssueListLoadTimeout)
        linearDebugLog("list refresh start cwd=\(cwd) staleCount=\(linearIssues.count) staleStates=[\(linearIssueStateCountSummary(linearIssues))]")
        linearIssueListTask = Task.detached(priority: .utility) {
            do {
                async let issuesRequest = LinearIssueClient.fetchIssueList(cwd: cwd, deadline: deadline, environment: environment, homeDirectory: homeDirectory)
                async let workflowStatesRequest = LinearIssueClient.fetchWorkflowStates(cwd: cwd, deadline: deadline, environment: environment, homeDirectory: homeDirectory)
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
                    self.isLinearIssueListRefreshing = false
                    self.linearIssues = issues
                    let workflowStateSource = workflowStates ?? self.linearIssueWorkflowStates
                    self.linearIssueWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(workflowStateSource, issues: issues)
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
                    self.isLinearIssueListRefreshing = false
                    let timedOut: Bool
                    if let clientError = error as? LinearIssueClientError,
                       case .requestTimedOut = clientError {
                        timedOut = true
                    } else {
                        timedOut = false
                    }
                    self.linearIssueListLoadState = .failed(
                        timedOut
                            ? "Linear refresh timed out. Click refresh to try again."
                            : "Unable to refresh Linear issues. Click refresh to try again."
                    )
                }
            }
        }
    }

    /// The Linear list is also refreshed while the user is working elsewhere in
    /// Banyan. This timer only starts the existing detached network task, so it
    /// does not block the main actor or replace the stale list while loading.
    private func installLinearIssueListRefreshTimer() {
        let interval = Self.linearIssueListRefreshInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLinearIssueList()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        linearIssueListRefreshTimer = timer
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
        linearIssueWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(cache.workflowStates ?? [], issues: cache.issues)
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

    private func mergeLinearWorkflowStates(_ workflowStates: [LinearWorkflowState]) {
        guard !workflowStates.isEmpty else { return }
        let mergedWorkflowStates = LinearIssuePolicy.mergedWorkflowStates(
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
        let cachedDetails = linearIssueDetailsCache[issueID]
        let hasStaleDetails = cachedDetails != nil
            || selectedLinearListIssueDetails?.identifier == issueID
        selectedLinearListIssueLoadState = hasStaleDetails ? .loaded : .loading
        if let cachedDetails {
            selectedLinearListIssueDetails = cachedDetails
        } else if !hasStaleDetails {
            selectedLinearListIssueDetails = nil
        }

        let cwd = selectedSession?.cwd ?? homeDirectory
        selectedLinearListIssueTask = Task.detached(priority: .utility) {
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.linearIssueDetailsCache[issueID] = issue
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState =
                        self.linearIssueDetailsCache[issueID] != nil
                        || self.selectedLinearListIssueDetails?.identifier == issueID
                        ? .loaded
                        : .failed(LinearIssueClient.message(for: error))
                }
            }
        }
    }

    func openSelectedLinearListIssue() {
        guard let url = selectedLinearListIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestLinearFilterFocus() {
        linearFilterFocusRequestID = UUID()
    }

    func requestCommandPalette() {
        commandPaletteRequestID = UUID()
    }

    func updateLinearIssueNavigationIDs(_ ids: [String]) {
        guard linearIssueNavigationIDs != ids else { return }
        linearIssueNavigationIDs = ids
        if let selectedLinearListIssueID,
           ids.contains(selectedLinearListIssueID) {
            return
        }
        selectedLinearListIssueID = ids.first
    }

    func updateSelectedLinearListIssueState(_ state: LinearWorkflowState) {
        guard let issueID = selectedLinearListIssueID else { return }
        selectedLinearListIssueTask?.cancel()
        selectedLinearListIssueLoadState = .updating(state.name)

        let cwd = selectedSession?.cwd ?? homeDirectory
        selectedLinearListIssueTask = Task.detached(priority: .userInitiated) {
            do {
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.linearIssueDetailsCache[issueID] = issue
                    self.selectedLinearListIssueDetails = issue
                    self.mergeLinearWorkflowStates(issue.workflowStates)
                    self.selectedLinearListIssueLoadState = .loaded
                    self.refreshLinearIssueList()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState = .failed(LinearIssueClient.message(for: error, action: "update"))
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
        let cwd = selectedSession?.cwd ?? homeDirectory
        Task.detached(priority: .userInitiated) {
            let errorMessage = Self.runBanyanWorktree(
                issueID: issueID,
                cwd: cwd,
                homeDirectory: homeDirectory,
                environment: environment
            )
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
        let server = ControlServer(store: self, host: host)
        server.start()
        controlServer = server
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
        let cwd = selectedSession?.cwd ?? homeDirectory
        let command = SessionLaunchPolicy.siblingRuntimeCommand(for: selectedSession?.agentProvider)
        return spawn(cwd: cwd, command: command, parentSessionID: selectedSession?.parentSessionID)
    }

    /// Spawn a sibling using the selected session's coding-agent runtime when it
    /// is one of the runtimes supported by the quick new-session shortcut.
    @discardableResult
    func spawnTerminalSiblingSession() -> BanyanSession {
        let cwd = selectedSession?.cwd ?? homeDirectory
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

        let cwd = selectedSession?.cwd ?? homeDirectory
        let id = uniqueID("scratch", avoidingLiveTmuxSessions: true)
        let session = BanyanSession(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: "Scratch",
            isTitlePinned: true,
            cwd: resolvedWorkingDirectory(cwd),
            command: "",
            tone: .neutral,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize,
            tmuxBackend: sessionBackend,
            telemetry: telemetry,
            host: host
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
        let cwd = selectedSession?.cwd ?? homeDirectory
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
        tone: SessionTone = .blue,
        select: Bool = true
    ) -> BanyanSession {
        let baseID = SessionIdentityPolicy.sanitizedID(proposedID ?? proposedTitle ?? "session")
        let id = uniqueID(baseID, avoidingLiveTmuxSessions: true)
        let cwd = resolvedWorkingDirectory(proposedCWD)
        let command = proposedCommand ?? ""
        let hasExplicitTitle = proposedTitle?.isEmpty == false
        let title = hasExplicitTitle
            ? proposedTitle!
            : PathDisplayName.make(path: cwd, homeDirectory: homeDirectory)
        let parentSessionID = SessionInputPolicy.normalizedOptionalText(proposedParentSessionID)
        let session = BanyanSession(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
                title: title,
            titleURL: SessionInputPolicy.normalizedTitleURL(proposedTitleURL),
                generatedTitle: nil,
                isTitlePinned: hasExplicitTitle,
            cwd: cwd,
            command: command,
            tone: tone,
            parentSessionID: parentSessionID,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize,
            tmuxBackend: sessionBackend,
            telemetry: telemetry,
            host: host
        )
        attach(session)
        sessions.append(session)
        if select {
            selectedSessionID = session.id
            refreshSelectedContextInfo(force: true)
        } else {
            // Keep the user's current selection/focus; still run the command so
            // background spawns (e.g. `agent run`) actually start.
            session.startBackgroundBackendIfNeeded()
        }
        saveSessions()
        return session
    }

    func respawn(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        historyResumeErrors.removeValue(forKey: id)
        // A closed session had its tmux backing killed, so reattaching would
        // rerun the original launch command from scratch. For codex/claude
        // sessions whose underlying agent session we resolved, rebuild the
        // command as a resume so prior context is restored instead of replayed.
        //
        // Sessions closed before the live transcript match ran — or persisted by
        // an older build — have no `agentSessionID`. Try to recover it from the
        // imported history now so those still resume instead of replaying.
        if SessionRecoveryPolicy.requiresDeepHistoryRecovery(
            status: session.status,
            provider: session.agentProvider,
            agentSessionID: session.agentSessionID
        ), !recoverAgentSessionID(for: session) {
            recoverAgentSessionIDAndRespawn(id: id)
            return
        }
        try respawnAfterHistoryRecovery(id: id)
    }

    func recover(id: String, select: Bool = true) throws {
        guard let session = sessions.first(where: { $0.id == id && $0.needsRecovery }) else {
            throw ControlError.notFound(id)
        }

        let recoveryCommand = session.agentProvider.flatMap { provider in
            guard let agentSessionID = session.agentSessionID,
                  [.codex, .claude].contains(provider) else {
                return nil
            }
            return historyBackend.resumeCommand(
                provider: provider,
                sourceID: agentSessionID,
                cwd: session.cwd,
                prompt: nil
            )
        }

        session.recoverFromMissingBackingSessionInBackground(command: recoveryCommand)
        if select {
            selectedSessionID = id
        }
        saveSessions()
    }

    func recoverAll(selectRecoveredSession: Bool = true) {
        for session in recoverySessions {
            try? recover(id: session.id, select: selectRecoveredSession)
        }
    }

    @discardableResult
    func openShellForClosedSession(id: String) throws -> BanyanSession {
        guard let session = sessions.first(where: { $0.id == id && $0.status == .closed }) else {
            throw ControlError.notFound(id)
        }
        return spawn(
            title: "zsh",
            cwd: session.cwd,
            command: HostShell.loginCommand(environment: environment)
        )
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
        let historyBackend = historyBackend
        Task.detached(priority: .userInitiated) {
            let preparedSourceID = historyBackend.prepareTrimmedTranscript(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                transcriptURL: nil
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let preparedSourceID,
                      let command = historyBackend.resumeCommand(
                        provider: provider,
                        sourceID: preparedSourceID,
                        cwd: cwd,
                        prompt: nil
                      ),
                      let session = self.sessions.first(where: { $0.id == id }) else {
                    try? self.respawn(id: id)
                    return
                }
                session.command = command
                session.markAgentSessionID(preparedSourceID)
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
    @discardableResult
    private func recoverAgentSessionID(for session: BanyanSession) -> Bool {
        guard let match = AgentSessionMatcher.bestHistoryResumeMatch(
            sessionCWD: session.cwd,
            sessionCreatedAt: session.createdAt,
            sessionUpdatedAt: session.updatedAt,
            sessionResetAt: session.lastConversationResetAt,
            provider: session.agentProvider,
            in: latestImportedHistory
        ) else {
            return false
        }
        session.markDetectedAgentProvider(match.provider)
        session.markAgentSessionID(match.sourceID)
        return true
    }

    /// Search beyond the bounded sidebar import before declaring a resume-capable
    /// history row unavailable. The scan stays off the main actor because old
    /// searchable rows may be much deeper than the recent shelf.
    private func recoverAgentSessionIDAndRespawn(id: String) {
        guard pendingRespawnRecoveryIDs.insert(id).inserted,
              let session = sessions.first(where: { $0.id == id }) else {
            return
        }
        let cwd = session.cwd
        let createdAt = session.createdAt
        let updatedAt = session.updatedAt
        let resetAt = session.lastConversationResetAt
        let provider = session.agentProvider
        let historyBackend = historyBackend

        Task.detached(priority: .userInitiated) { [weak self] in
            let imported = historyBackend.load(maxPerProvider: .max)
            let match = AgentSessionMatcher.bestHistoryResumeMatch(
                sessionCWD: cwd,
                sessionCreatedAt: createdAt,
                sessionUpdatedAt: updatedAt,
                sessionResetAt: resetAt,
                provider: provider,
                in: imported
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingRespawnRecoveryIDs.remove(id)
                guard let session = self.sessions.first(where: { $0.id == id }),
                      session.status == .closed else {
                    return
                }
                if let match {
                    session.markDetectedAgentProvider(match.provider)
                    session.markAgentSessionID(match.sourceID)
                    try? self.respawnAfterHistoryRecovery(id: id)
                } else {
                    self.historyResumeErrors[id] = SessionRecoveryPolicy.missingResumeMessage(provider: provider)
                }
            }
        }
    }

    func isRecoveringHistoryResume(id: String) -> Bool {
        pendingRespawnRecoveryIDs.contains(id)
    }

    func historyResumeError(id: String) -> String? {
        historyResumeErrors[id]
    }

    private func respawnAfterHistoryRecovery(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        if let resumeCommand = SessionRecoveryPolicy.resumeCommand(
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
        session.mark(status: status, tone: tone, title: title, titleURL: SessionInputPolicy.normalizedTitleURL(titleURL))
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
        if sidebarMode == .linear {
            openSelectedLinearListIssue()
            return
        }
        guard let url = selectedLinearIssueURL else { return }
        NSWorkspace.shared.open(url)
    }

    func openSelectedGitHubIssue() {
        if let value = selectedContextInfo?.githubIssueURL, let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshSelectedGitHubIssue(force: Bool = false) {
        guard let session = selectedSession, session.status != .closed,
              let value = selectedContextInfo?.githubIssueURL, let url = URL(string: value) else {
            selectedGitHubIssueTask?.cancel()
            selectedGitHubIssueTask = nil
            selectedGitHubIssueURL = nil
            selectedGitHubIssueDetails = nil
            selectedGitHubIssueLoadState = .idle
            return
        }
        guard force || selectedGitHubIssueURL != url || selectedGitHubIssueDetails == nil else { return }
        selectedGitHubIssueTask?.cancel()
        selectedGitHubIssueURL = url
        selectedGitHubIssueDetails = nil
        selectedGitHubIssueLoadState = .loading
        let sessionID = session.id
        let cwd = session.cwd
        selectedGitHubIssueTask = Task.detached(priority: .utility) {
            do {
                let details = try await GitHubIssueClient.fetchIssue(
                    url: url,
                    cwd: cwd,
                    environment: environment,
                    homeDirectory: homeDirectory
                )
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.githubIssueURL == url.absoluteString,
                          self.selectedGitHubIssueURL == url else { return }
                    self.selectedGitHubIssueTask = nil
                    self.selectedGitHubIssueDetails = details
                    self.selectedGitHubIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID,
                          self.selectedGitHubIssueURL == url else { return }
                    self.selectedGitHubIssueTask = nil
                    self.selectedGitHubIssueLoadState = .failed(GitHubIssueClient.message(for: error))
                }
            }
        }
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
            if selectedLinearIssueDetails != nil { selectedLinearIssueDetails = nil }
            if selectedLinearIssueLoadState != .idle { selectedLinearIssueLoadState = .idle }
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
        let cachedDetails = linearIssueDetailsCache[issueID]
        let hasStaleDetails = cachedDetails != nil
            || selectedLinearIssueDetails?.identifier == issueID
        if let cachedDetails {
            selectedLinearIssueDetails = cachedDetails
        } else if !hasStaleDetails {
            selectedLinearIssueDetails = nil
        }
        selectedLinearIssueLoadState = hasStaleDetails ? .loaded : .loading

        let cwd = session.cwd
        let sessionID = session.id
        selectedLinearIssueTask = Task.detached(priority: .utility) {
            do {
                let issue = try await LinearIssueClient.fetchIssue(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self,
                          self.selectedSessionID == sessionID,
                          self.selectedContextInfo?.linearIssueID == issueID,
                          self.selectedLinearIssueIdentifier == issueID else {
                        return
                    }
                    self.linearIssueDetailsCache[issueID] = issue
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
                    if self.linearIssueDetailsCache[issueID] != nil
                        || self.selectedLinearIssueDetails?.identifier == issueID {
                        self.selectedLinearIssueLoadState = .loaded
                        self.startSelectedLinearIssueStatusRefreshIfNeeded()
                    } else {
                        self.selectedLinearIssueLoadState = .failed(LinearIssueClient.message(for: error))
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
                try await LinearIssueClient.updateIssueState(identifier: issueID, state: state, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
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
                    self.selectedLinearIssueLoadState = .failed(LinearIssueClient.message(for: error, action: "update"))
                }
            }
        }
    }

    func updateSelectedLinearIssueDescription(taskIndex: Int) {
        guard let session = selectedSession, session.status != .closed,
              let issueID = selectedContextInfo?.linearIssueID,
              let issue = selectedLinearIssueDetails, let description = issue.description,
              let newDescription = MarkdownTaskListEditor.toggledDescription(description, taskIndex: taskIndex) else { return }
        pendingSelectedLinearDescriptionUpdate = .init(issueID: issueID, oldDescription: issue.description, newDescription: newDescription)
        let optimistic = issue.applying(description: newDescription)
        selectedLinearIssueDetails = optimistic
        linearIssueDetailsCache[issueID] = optimistic
        selectedLinearIssueLoadState = .updatingDescription
        saveSelectedLinearIssueDescription(issueID: issueID, description: newDescription, cwd: session.cwd, sessionID: session.id)
    }

    func retrySelectedLinearIssueDescription() {
        guard let pending = pendingSelectedLinearDescriptionUpdate, let session = selectedSession,
              selectedContextInfo?.linearIssueID == pending.issueID else { return }
        selectedLinearIssueLoadState = .updatingDescription
        saveSelectedLinearIssueDescription(issueID: pending.issueID, description: pending.newDescription, cwd: session.cwd, sessionID: session.id)
    }

    private func saveSelectedLinearIssueDescription(issueID: String, description: String, cwd: String, sessionID: String) {
        selectedLinearIssueTask?.cancel()
        selectedLinearIssueTask = Task.detached(priority: .userInitiated) {
            do {
                try await LinearIssueClient.updateIssueDescription(identifier: issueID, description: description, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID, self.selectedContextInfo?.linearIssueID == issueID else { return }
                    self.pendingSelectedLinearDescriptionUpdate = nil
                    self.selectedLinearIssueTask = nil
                    self.selectedLinearIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedSessionID == sessionID, self.selectedContextInfo?.linearIssueID == issueID else { return }
                    self.selectedLinearIssueTask = nil
                    if let pending = self.pendingSelectedLinearDescriptionUpdate, let issue = self.selectedLinearIssueDetails {
                        let reverted = issue.applying(description: pending.oldDescription)
                        self.selectedLinearIssueDetails = reverted
                        self.linearIssueDetailsCache[issueID] = reverted
                    }
                    self.selectedLinearIssueLoadState = .failed("Unable to save description")
                }
            }
        }
    }

    func updateSelectedLinearListIssueDescription(taskIndex: Int) {
        guard let issueID = selectedLinearListIssueID, let issue = selectedLinearListIssueDetails,
              let description = issue.description,
              let newDescription = MarkdownTaskListEditor.toggledDescription(description, taskIndex: taskIndex) else { return }
        pendingSelectedLinearListDescriptionUpdate = .init(issueID: issueID, oldDescription: issue.description, newDescription: newDescription)
        let optimistic = issue.applying(description: newDescription)
        selectedLinearListIssueDetails = optimistic
        linearIssueDetailsCache[issueID] = optimistic
        selectedLinearListIssueLoadState = .updatingDescription
        saveSelectedLinearListIssueDescription(issueID: issueID, description: newDescription, cwd: selectedSession?.cwd ?? homeDirectory)
    }

    func retrySelectedLinearListIssueDescription() {
        guard let pending = pendingSelectedLinearListDescriptionUpdate, selectedLinearListIssueID == pending.issueID else { return }
        selectedLinearListIssueLoadState = .updatingDescription
        saveSelectedLinearListIssueDescription(issueID: pending.issueID, description: pending.newDescription, cwd: selectedSession?.cwd ?? homeDirectory)
    }

    private func saveSelectedLinearListIssueDescription(issueID: String, description: String, cwd: String) {
        selectedLinearListIssueTask?.cancel()
        selectedLinearListIssueTask = Task.detached(priority: .userInitiated) {
            do {
                try await LinearIssueClient.updateIssueDescription(identifier: issueID, description: description, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.pendingSelectedLinearListDescriptionUpdate = nil
                    self.selectedLinearListIssueTask = nil
                    self.selectedLinearListIssueLoadState = .loaded
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.selectedLinearListIssueID == issueID else { return }
                    self.selectedLinearListIssueTask = nil
                    if let pending = self.pendingSelectedLinearListDescriptionUpdate, let issue = self.selectedLinearListIssueDetails {
                        let reverted = issue.applying(description: pending.oldDescription)
                        self.selectedLinearListIssueDetails = reverted
                        self.linearIssueDetailsCache[issueID] = reverted
                    }
                    self.selectedLinearListIssueLoadState = .failed("Unable to save description")
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
                let status = try await LinearIssueClient.fetchIssueStatus(identifier: issueID, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
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
        let updatedIssue = issue.applying(status: status)
        selectedLinearIssueDetails = updatedIssue
        linearIssueDetailsCache[updatedIssue.identifier] = updatedIssue
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
        if selectedPullRequestDetails != nil { selectedPullRequestDetails = nil }
        if selectedPullRequestLoadState != .idle { selectedPullRequestLoadState = .idle }
        if isPullRequestPreviewPresented { isPullRequestPreviewPresented = false }
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
        let replacementID = selectedSessionID == id
            ? preferredSelectionAfterClosing(id: id)
            : nil
        detachChildren(of: id, to: session.parentSessionID)
        if session.isImportedHistory {
            session.terminate(markClosed: true)
        } else {
            session.killBackingSession()
        }
        if selectedSessionID == id {
            selectedSessionID = replacementID ?? visibleSessions.first?.id
        }
        saveSessions()
        refreshImportedHistory()
    }

    func remove(id: String) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        let replacementID = selectedSessionID == id
            ? preferredSelectionAfterClosing(id: id)
            : nil
        if sessions[index].isImportedHistory {
            sessions[index].status = .closed
            if selectedSessionID == id {
                selectedSessionID = replacementID ?? visibleSessions.first?.id
            }
            refreshImportedHistory()
            return
        }
        let parentSessionID = sessions[index].parentSessionID
        detachChildren(of: id, to: parentSessionID)
        sessions[index].killBackingSession()
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = replacementID ?? visibleSessions.first?.id
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
              let sourceID = historyBackend.sourceID(fromImportedSessionID: history.id, provider: provider),
              let command = historyBackend.resumeCommand(
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
              let sourceID = historyBackend.sourceID(fromImportedSessionID: history.id, provider: provider) else {
            _ = try? resumeImportedHistory(id: id, prompt: prompt)
            return
        }
        let cwd = history.cwd
        let title = history.displayTitle
        let transcriptURL = history.historyTranscriptURL
        let historyBackend = historyBackend
        Task.detached(priority: .userInitiated) {
            let preparedSourceID = historyBackend.prepareTrimmedTranscript(
                provider: provider,
                sourceID: sourceID,
                cwd: cwd,
                transcriptURL: transcriptURL
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let preparedSourceID,
                      let command = historyBackend.resumeCommand(
                        provider: provider,
                        sourceID: preparedSourceID,
                        cwd: cwd,
                        prompt: prompt
                      ) else {
                    _ = try? self.resumeImportedHistory(id: id, prompt: prompt)
                    return
                }
                self.spawn(
                    id: "\(provider.rawValue)-\(String(preparedSourceID.prefix(8)))",
                    title: title,
                    cwd: cwd,
                    command: command,
                    tone: .blue
                )
            }
        }
    }

    func select(id: String) {
        selection.selectedSessionID = id
    }

    func moveSidebarSessions(in groupID: String, from sourceOffsets: IndexSet, to destinationOffset: Int) {
        let groups = sessionSidebarGroups
        guard let group = groups.first(where: { $0.id == groupID }) else { return }

        let activeSidebarIDs = groups.flatMap { $0.items.map(\.id) }
        let groupSessionIDs = group.items.map(\.id)
        guard let reorderedIDs = SessionSidebarOrdering.reorderedIDs(
            activeIDs: activeSidebarIDs,
            groupIDs: groupSessionIDs,
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
        guard let reorderedIDs = SessionSidebarOrdering.reorderedIDs(
            activeIDs: activeSidebarIDs,
            groupIDs: groupSessionIDs,
            sourceID: sourceID,
            targetID: targetID
        ), reorderedIDs != activeSidebarIDs else {
            return
        }

        applySidebarSessionOrder(activeSidebarIDs: activeSidebarIDs, reorderedIDs: reorderedIDs)
    }

    func selectNextSession() {
        selectAdjacentSession(direction: .next)
    }

    func selectPreviousSession() {
        selectAdjacentSession(direction: .previous)
    }

    func selectNextLinearIssue() {
        selectAdjacentLinearIssue(direction: .next)
    }

    func selectPreviousLinearIssue() {
        selectAdjacentLinearIssue(direction: .previous)
    }

    private func selectAdjacentLinearIssue(direction: SessionSelectionDirection) {
        let orderedIDs = linearIssueNavigationIDs ?? linearIssues.map(\.identifier)
        guard let issueID = SessionSelectionNavigator.adjacentID(
            in: orderedIDs,
            selectedID: selectedLinearListIssueID,
            direction: direction
        ) else {
            return
        }
        selectedLinearListIssueID = issueID
    }

    func selectNextWorkableSession() {
        guard let id = SessionSelectionNavigator.nextMatchingID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            isMatch: isWorkableSession
        ) else {
            return
        }
        selection.selectedSessionID = id
    }

    var hasWorkableSession: Bool {
        sidebarSessions.contains { isWorkableSession($0.id) }
    }

    @discardableResult
    func selectSession(shortcutIndex: Int) -> Bool {
        guard let id = SessionSelectionNavigator.directID(
            in: sidebarSessions.map(\.id),
            oneBasedIndex: shortcutIndex
        ) else {
            return false
        }
        selection.selectedSessionID = id
        return true
    }

    func requestCloseSelectedSession() {
        guard let selectedSession else { return }
        requestClose(id: selectedSession.id)
    }

    @discardableResult
    func dispatchHandoff(id: String, bypassEligibility: Bool = false) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }),
              (bypassEligibility || session.canDispatchHandoff),
              !pendingHandoffJobs.contains(where: { $0.sessionID == id }) else {
            return false
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
            return false
        }

        pendingHandoffJobs.append(job)
        Task.detached(priority: .utility) {
            let result = runHandoffDispatch(
                cwd: job.cwd,
                homeDirectory: homeDirectory,
                environment: environment
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingHandoffJobs.removeAll { $0.id == job.id }
                if case .failure = result {
                    try? self.respawn(id: job.sessionID)
                    self.handoffNotice = "Handoff could not be started. The session was restored."
                }
            }
        }
        return true
    }

    func handleHandoffShortcut() {
        guard let session = selectedSession else {
            handoffNotice = "Select a session before starting handoff."
            return
        }
        guard !pendingHandoffJobs.contains(where: { $0.sessionID == session.id }) else {
            handoffNotice = "Handoff is already running for this session."
            return
        }
        guard dispatchHandoff(id: session.id, bypassEligibility: true) else {
            handoffNotice = "Handoff could not be started."
            return
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
        return URL(string: LinearIssueReference.issueURL(
            for: selectedLinearListIssueID,
            environment: environment
        ))
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
            githubIssueNumber: nil,
            githubIssueTitle: nil,
            githubIssueURL: nil,
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
            githubIssueNumber: nil,
            githubIssueTitle: nil,
            githubIssueURL: nil,
            pullRequestNumber: nil,
            pullRequestTitle: nil,
            pullRequestURL: nil
        )
    }

    func requestClose(id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if hasActiveChildren(id) || SessionLifecyclePolicy.isOngoingCodingAgentSession(
            status: session.status,
            provider: session.agentProvider
        ) {
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
        guard let parentSessionID = SessionInputPolicy.normalizedOptionalText(parentSessionID) else {
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
            telemetry.noteSessionFirstOutput(sessionID: session.id)
            self.detectAttention(in: text, for: session)
        }
        session.onStatusSignal = { [weak session] status in
            guard let session else { return }
            self.attentionNotifier.notifyIfNeeded(session: session, status: status)
        }
        session.onProjectContextObserved = { [weak self, weak session] cwd, context in
            guard let self else { return }
            for sibling in self.sessions where sibling !== session && sibling.status != .closed && sibling.cwd == cwd {
                sibling.applyProjectContext(context)
            }
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
            telemetry.noteSessionFirstOutput(sessionID: session.id)
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

    func focusSelectedTerminal() {
        requestTerminalFocus()
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
        let historyBackend = historyBackend
        Task.detached(priority: .utility) {
            let imported = historyBackend.load(maxPerProvider: SessionHistoryPresentation.recoveryImportLimit)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.applyImportedHistory(imported)
                self.isHistoryImportRunning = false
                let shouldRunPendingImport = self.isHistoryImportPending
                self.isHistoryImportPending = false
                if spawnDefaultIfEmpty, self.visibleSessions.isEmpty {
                    self.spawn(cwd: homeDirectory)
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

    private func refreshLiveAgentTitles(from imported: [ImportedAgentSession]) {
        let candidates = imported.filter { [.claude, .codex].contains($0.provider) }
        guard !candidates.isEmpty else { return }

        let liveSessions = sessions.filter {
            AgentSessionMatcher.participatesInLiveAgentMatch(
                isImportedHistory: $0.isImportedHistory,
                status: $0.status,
                provider: $0.agentProvider
            )
        }
        let inputs = liveSessions.map {
            AgentSessionMatchInput(
                id: $0.id,
                cwd: $0.cwd,
                createdAt: $0.createdAt,
                resetAt: $0.lastConversationResetAt,
                provider: $0.agentProvider
            )
        }
        let matchesBySessionID = AgentSessionMatcher.bestPromptTitleAssignments(
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

    /// Resolve the provider session behind a closed Banyan row. The live title
    /// matcher intentionally uses a narrow launch-time window to avoid assigning
    /// the wrong title among concurrent sessions. Reopen can be more practical:
    /// Codex and Claude scope their resume pickers by cwd, and Linear worktrees are
    /// normally unique. Prefer the strict match, then use the exact provider + cwd;
    /// if several transcripts share that directory, choose the one whose last
    /// activity is closest to when the Banyan session was last active.
    private func detectAttention(in text: String, for session: BanyanSession) {
        guard let result = detector.detect(in: text), session.status != .closed else { return }
        guard result.status == .asking || result.status == .needInput else { return }
        guard ![.executing, .longRunningShell, .subagents].contains(session.status) else { return }
        session.mark(status: result.status, tone: result.tone)
    }

    private func runSupervisorTick(sessionID: String? = nil) {
        guard !isSupervisorTickRunning else { return }
        let inputs = sessions.compactMap { session -> SessionStatusObservationInput? in
            guard session.status != .closed && (sessionID == nil || session.id == sessionID) else {
                return nil
            }
            guard SessionLifecyclePolicy.participatesInSupervisorTick(
                isProcessStarted: session.isProcessStarted,
                isRestored: session.isRestored
            ) else {
                return nil
            }
            return SessionStatusObservationInput(
                id: session.id,
                tmuxSessionName: session.tmuxSessionName,
                command: session.command,
                status: session.status,
                isAwaitingAttach: !session.isProcessStarted
            )
        }
        guard !inputs.isEmpty else { return }

        isSupervisorTickRunning = true
        let backend = tmuxBackend
        let processTable = processTable.snapshot()

        Task.detached(priority: .utility) { [weak self] in
            // Time the whole tick: `ps` snapshot + per-session tmux inspection. This
            // is the app's steady-state energy cost, previously untracked and so
            // invisible in `banyanctl perf report`.
            let tickStartedAt = DispatchTime.now()
            let synchronizer = SessionStatusSynchronizer(
                backend: backend,
                processTable: processTable
            )
            let results = synchronizer.observe(inputs)

            telemetry.recordDuration(
                "supervisor.tick",
                durationMS: PerformanceTelemetry.elapsedMS(since: tickStartedAt),
                detail: "sessions=\(inputs.count)"
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                let didChangePersistentState = self.applySupervisorResults(results)
                self.isSupervisorTickRunning = false
                if didChangePersistentState {
                    self.saveSessions()
                }
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
            telemetry.recordDuration(
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
            telemetry.recordDuration(
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
            telemetry.recordDuration(
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
                let details = try await GitHubPullRequestClient.fetchPullRequest(
                    url: url,
                    cwd: cwd,
                    environment: environment,
                    homeDirectory: homeDirectory
                )
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
            homeDirectory: homeDirectory,
            environment: environment,
            title: session.title,
            titleURL: session.titleURL,
            displayTitle: session.displayTitle
        )
    }

    private func refreshSelectedContextInfoIfStale() {
        guard Date().timeIntervalSince(selectedContextResolvedAt) > 30 else { return }
        refreshSelectedContextInfo(force: true)
    }

    @discardableResult
    private func applySupervisorResults(_ results: [SessionStatusObservation]) -> Bool {
        var didUpdateProvider = false
        var didChangePersistentState = false
        for result in results {
            guard let session = sessions.first(where: { $0.id == result.id }), session.status != .closed else {
                continue
            }
            if session.detectedAgentProvider != result.provider {
                session.markDetectedAgentProvider(result.provider)
                didUpdateProvider = true
                didChangePersistentState = true
            }
            if let currentPath = result.currentPath, session.cwd != currentPath {
                session.updateCurrentDirectory(currentPath)
                didChangePersistentState = true
            }
            if session.status != result.status || session.tone != result.tone {
                session.mark(status: result.status, tone: result.tone)
                didChangePersistentState = true
            }
        }
        if didUpdateProvider {
            refreshLiveAgentTitles(from: latestImportedHistory)
        }
        return didChangePersistentState
    }

    private func isScratchTerminalWindow(_ window: NSWindow?) -> Bool {
        window?.identifier == Self.scratchWindowIdentifier
    }

    private func scratchWindowTitle(for session: BanyanSession) -> String {
        "Scratch - \(PathDisplayName.make(path: session.cwd, homeDirectory: homeDirectory))"
    }

    /// Chooses the nearest visible session before the closing session is removed.
    /// Sidebar groups are already in their rendered order, so this preserves the
    /// user's project/session navigation order across all sort modes.
    private func preferredSelectionAfterClosing(id: String) -> String? {
        let groups = sessionSidebarGroups.map { group in
            SessionSelectionGroup(
                id: group.id,
                items: group.items.map { item in
                    SessionSelectionItem(
                        id: item.id,
                        parentSessionID: item.session.parentSessionID
                    )
                }
            )
        }
        return SessionClosingSelectionPolicy.preferredIDAfterClosing(
            closingID: id,
            groups: groups
        )
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
        WorkingDirectoryPolicy.resolve(
            proposedDirectory: cwd,
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
    }

    nonisolated private static func runBanyanWorktree(
        issueID: String,
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> String? {
        let executablePath = "\(homeDirectory)/bin/banyan-worktree"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return "Missing ~/bin/banyan-worktree"
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["--banyan", issueID]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = AppProcessEnvironment.make(
            base: environment,
            shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: environment),
            pathAdditions: [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/go/bin",
            "\(homeDirectory)/.nix-profile/bin",
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
        let parentIDForChildren = SessionInputPolicy.normalizedOptionalText(newParentID)
        for session in sessions where session.parentSessionID == parentID {
            session.parentSessionID = parentIDForChildren
            session.touch()
        }
    }

    private func selectAdjacentSession(direction: SessionSelectionDirection) {
        guard let id = SessionSelectionNavigator.adjacentID(
            in: sidebarSessions.map(\.id),
            selectedID: selection.selectedSessionID,
            direction: direction
        ) else {
            return
        }
        selection.selectedSessionID = id
    }

    private func isWorkableSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return SessionLifecyclePolicy.isWorkable(
            status: session.status,
            isImportedHistory: session.isImportedHistory
        )
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
        if avoidingLiveTmuxSessions, tmuxBackend.hasSession(named: SessionIdentityPolicy.sessionName(for: id)) {
            return false
        }
        return true
    }
}

private func runHandoffDispatch(
    cwd: String,
    homeDirectory: String,
    environment: [String: String]
) -> Result<Void, HandoffDispatchError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["\(homeDirectory)/bin/handoff", "dispatch"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = AppProcessEnvironment.make(
        base: environment,
        shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: environment)
    )
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
