import BanyanCore
import Foundation
import AppKit
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    static let scratchWindowIdentifier = NSUserInterfaceItemIdentifier("banyan.scratch-terminal")

    @Published var sessions: [BanyanSession] = [] {
        didSet {
            sidebarGroupsRevision &+= 1
            sidebarHistoryRevision &+= 1
            EnergyTrace.count("store.sessions.mutate")
        }
    }
    @Published var terminalFocusRequestID = UUID()
    @Published var commandPaletteRequestID = UUID()
    @Published var scratchTerminalFocusRequestID = UUID()
    @Published var scratchSession: TerminalSession?
    // Context selection owns issue loading. Mounting the detail panel must not
    // force another fetch and cancel/restart the one already in flight.
    @Published var selectedContextInfo: SessionContextInfo? {
        didSet {
            refreshSelectedLinearIssue()
            refreshSelectedGitHubIssue()
        }
    }
    @Published var selectedLinearIssueDetails: LinearIssueDetails?
    @Published var selectedLinearIssueLoadState: LinearIssueLoadState = .idle
    @Published var selectedGitHubIssueDetails: GitHubIssueDetails?
    @Published var selectedGitHubIssueLoadState: GitHubIssueLoadState = .idle
    @Published var isPullRequestPreviewPresented = false
    @Published var selectedPullRequestDetails: GitHubPullRequestDetails?
    @Published var selectedPullRequestLoadState: GitHubPullRequestLoadState = .idle
    @Published var sidebarMode: SidebarMode = .sessions {
        didSet {
            if sidebarMode != oldValue {
                telemetry.axiomExporter?.sendAppLifecycle("sidebar.mode_change", attributes: [
                    "sidebar.mode": sidebarMode.rawValue,
                    "sidebar.previous_mode": oldValue.rawValue,
                ])
            }
            if sidebarMode == .linear {
                refreshLinearIssueListOnEnter()
            }
        }
    }
    @Published var linearIssues: [LinearIssueSummary] = []
    @Published var linearIssueWorkflowStates: [LinearWorkflowState] = []
    @Published var linearIssueListLoadState: LinearIssueListLoadState = .idle
    @Published var isLinearIssueListRefreshing = false
    @Published var linearIssueNavigationIDs: [String]?
    @Published var selectedLinearListIssueID: String? {
        didSet {
            refreshSelectedLinearListIssue()
        }
    }
    @Published var selectedLinearListIssueDetails: LinearIssueDetails?
    @Published var selectedLinearListIssueLoadState: LinearIssueLoadState = .idle
    @Published var linearFilterFocusRequestID = UUID()
    @Published var pendingHandoffJobs: [HandoffJob] = []
    @Published var isHandoffAvailable = false
    @Published var handoffNotice: String?
    @Published var addSessionDraft: AddSessionDraft?
    private(set) var sessionSwitchRequestedAt: DispatchTime?
    let selection = SessionSelection()
    var lastPublishedAgentReservations: Set<String> = []
    let agentAdmission: AgentAdmissionController
    var admissionPuckSessions: [String: PuckSession] = [:]
    var admissionTerminals: [String: TerminalSession] = [:]
    var admissionWatchOwners: [String: (id: String, generation: UUID, pid: Int32, identity: AgentProcessIdentity?)] = [:]
    lazy var admissionProcessExitMonitor = SupervisorProcessExitMonitor { [weak self] key in
        self?.noteAgentAdmissionProcessExit(key: key)
    }
    @Published var maximumConcurrentAgents: Int = AgentAdmissionController.defaultLimit {
        didSet {
            let bounded = min(AgentAdmissionController.maximumLimit, max(1, maximumConcurrentAgents))
            if maximumConcurrentAgents != bounded { maximumConcurrentAgents = bounded }
            freezePreferences.set(maximumConcurrentAgents, forKey: AgentAdmissionController.defaultsKey)
            agentAdmission.setLimit(maximumConcurrentAgents)
        }
    }
    var pendingAgentFreezeIDs: Set<String> = []
    var isAutoFreezeRunning = false
    var nextAutoFreezeProbeAt = Date.distantPast
    var isFrozenReconciliationRunning = false
    var isAgentFreezeShuttingDown = false
    var nextDeepSuspendProbeAt = Date.distantPast
    var isDeepSuspendPassRunning = false
    /// Queued work reclaims a verified-idle reservation, one command at a time.
    var isReclaimingAgentSlotForQueue = false
    var deepSuspendPressureSource: DispatchSourceMemoryPressure?
    var isUnderMemoryPressure = false
    var deepSuspendHistory: any SessionHistoryBackend { historyBackend }
    let freezePreferences: UserDefaults
    @Published var autoFreezeAgents = false {
        didSet {
            freezePreferences.set(autoFreezeAgents, forKey: "autoFreezeAgents")
            nextAutoFreezeProbeAt = .distantPast
            if !autoFreezeAgents { resumeAllFrozenAgents() }
            if didStartSupervisor { rescheduleSupervisor() }
        }
    }
    @Published var agentFreezeIdleMinutes: Double = 10 {
        didSet {
            freezePreferences.set(agentFreezeIdleMinutes, forKey: "agentFreezeIdleMinutes")
            nextAutoFreezeProbeAt = .distantPast
            if didStartSupervisor { rescheduleSupervisor() }
        }
    }
    @Published var selectedSessionID: String? {
        didSet {
            resumeFrozenForInteraction(id: selectedSessionID)
            selection.syncFromStore(selectedSessionID)
            if oldValue != selectedSessionID {
                if let selectedSession { rememberRecentProject(for: selectedSession, usedAt: Date()) }
                sidebarGroupsRevision &+= 1
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
            if !codexThreads.states.isEmpty {
                let nativeID = (selectedSession as? CodexSession).flatMap { $0.status != .closed && !$0.isSuspended ? $0.id : nil }
                Task { [weak self] in try? await self?.codexThreads.select(sessionID: nativeID) }
            }
            saveWorkspaceSoon()
            requestTerminalFocus()
            refreshSelectedContextInfo(force: true)
            if oldValue != selectedSessionID, let selectedSessionID {
                resetSupervisorObservationBackoff(for: selectedSessionID)
                runSupervisorTick(sessionID: selectedSessionID)
            }
        }
    }
    @Published var sortMode: SortMode = .manual {
        didSet {
            sidebarGroupsRevision &+= 1
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
    /// Experiment switch for SwiftTerm's Metal renderer. Kept in `UserDefaults`
    /// rather than the workspace snapshot: it is a rendering experiment, not
    /// part of the workspace a user would expect to carry around.
    @Published var terminalRenderer: TerminalRendererPreference = .coreGraphics {
        didSet {
            guard terminalRenderer != oldValue else { return }
            // A renderer pinned for one launch must not write itself into the
            // user's stored preference.
            if !TerminalRendererPreference.isPinnedByEnvironment(ProcessInfo.processInfo.environment) {
                UserDefaults.standard.set(
                    terminalRenderer.rawValue,
                    forKey: TerminalRendererPreference.defaultsKey
                )
            }
            applyTerminalRenderer()
        }
    }
    /// Applies only to newly launched or explicitly resumed Codex sessions.
    /// Existing sessions keep their persisted launch command so switching this
    /// setting cannot steal or release a live thread writer.
    @Published var enableCodexAppServerMode = false {
        didSet {
            saveWorkspace()
        }
    }
    @Published var autoRetryCodexFailures = true {
        didSet {
            sessions.forEach { $0.autoRetryCodexFailures = autoRetryCodexFailures }
            saveWorkspace()
        }
    }
    /// Independent rollout gate for the Banyan-owned native client.
    @Published var enableNativeCodex = false {
        didSet {
            codexThreads.isEnabled = enableNativeCodex
            Task { [weak self] in
                guard let self else { return }
                do { try await self.codexThreads.synchronizeRollout() }
                catch { self.codexSessionError = error.localizedDescription }
            }
            saveWorkspace()
        }
    }
    /// Opt-in gate for the worktree handoff affordance. Installing the handoff
    /// command used to be the whole switch, so the button appeared in any
    /// eligible row whether or not the workflow was still in use.
    @Published var enableHandoffAction = false {
        didSet {
            guard enableHandoffAction != oldValue else { return }
            refreshHandoffAvailability()
            saveWorkspace()
        }
    }
    /// How long a closed session stays in `state.sqlite`, in days. `0` keeps
    /// everything. Applied at launch before snapshots are built, and on demand
    /// from Preferences or `banyanctl prune` — never from the save path, which
    /// runs on every supervisor tick.
    @Published var sessionRetentionDays = SessionRetentionPolicy.defaultRetentionDays {
        didSet {
            guard sessionRetentionDays != oldValue else { return }
            saveWorkspace()
        }
    }
    @Published var backgroundSessionRoots: Set<String> = [] {
        didSet { sidebarGroupsRevision &+= 1 }
    }
    @Published var backgroundPresentationError: String?
    var workOverview: WorkitOverview? {
        didSet { workSummaryRevision &+= 1 }
    }
    var workOverviewError: String?
    // Fetch coordination only; no view reads this flag. Publishing it redraws
    // the whole session list before and after every overview request.
    var isRefreshingWorkOverview = false
    var workSummaryRevision = 0 {
        didSet {
            sidebarGroupsRevision &+= 1
            scheduleWorkSummaryUpdate()
        }
    }
    var workStates: [String: SessionWorkState] = [:]
    var workSummaryUpdateTask: Task<Void, Never>?
    var workOverviewRefreshTask: Task<Void, Never>?
    var workOverviewRefreshRequested = false
    var cachedWorkSummaries: [String: SessionWorkSummary] = [:]
    var cachedWorkSummaryRevision = -1
    var cachedWorkSidebarRevision = -1
    var cachedWorkOverviewTime: String?
    @Published var pendingCloseSessionID: String?
    @Published var pauseCloseInFlightIDs: Set<String> = []
    @Published var pauseCloseError: String?
    var pauseCloseRetrySessionID: String?
    var pauseCloseAttempts: [String: PauseCloseAttempt] = [:]
    var pauseCloseUITaskIDs: Set<String> = []
    let workitPauseClient: any WorkitPauseClient
    let pauseCloseProjectionTimeout: Duration
    /// Per-project last-used "new session" kind, keyed by project group ID. Drives
    /// the project header's split "+" button so it reopens whatever was launched
    /// last for that project. Persisted in `UserDefaults`.
    @Published var projectLaunchByGroup: [String: String] = [:]
    @Published var sessionLaunchProfiles = NewSessionLaunch.builtInDefaults
    @Published var sessionShortcutConfiguration = SessionShortcutConfiguration()
    @Published var sessionShortcutConfigurationDiagnostic: String?
    /// Why the last puck session Banyan tried to create or open is not on screen.
    @Published var puckSessionError: String?
    /// The local daemon behind every `PuckSession`.
    let puckDaemon: any PuckDaemonService
    var puckWatchTask: Task<Void, Never>?
    var puckWatchGeneration = 0
    var isPuckWatchConnected = false
    var puckObservation: (any PuckDaemonObservation)?
    var puckPresenceMonitor: PuckPresenceMonitor?
    var lastPuckSnapshotAt: Date?

    deinit {
        deepSuspendPressureSource?.cancel()
        puckWatchTask?.cancel()
        puckObservation?.cancel()
    }
    var isPuckSyncRunning = false
    /// Daemon sessions Banyan is creating. The daemon lists one before its
    /// create returns, and a listing must not add it as a stranger's session.
    var pendingPuckCreationIDs: Set<String> = []
    /// Bumped whenever Banyan adds a puck row itself. A listing requested
    /// before then may predate the row, so it says nothing about its absence.
    var puckRowEpoch = 0
    /// Whether the last daemon snapshot succeeded. A watch drives live state;
    /// sparse listings discover empty sessions, which emit no creation event.
    var isPuckDaemonReachable = false
    /// Daemon sessions outside the working set: listed by `puckd`, with no live
    /// sidebar row. Rebuilt from every listing, so nothing about them persists.
    @Published var backgroundPuckSummaries: [PuckSessionSummary] = []
    /// The daemon's last complete listing, to re-derive the background list
    /// when the working set changes between listings.
    var lastPuckSummaries: [PuckSessionSummary] = []
    /// Puck rows restored from a build that added every listed daemon session
    /// to the sidebar, so their origin is unknown. Cleared per row by an
    /// explicit open or turn, or by removing the row.
    @Published var legacyPuckSessionIDs: Set<String> = [] {
        didSet {
            guard legacyPuckSessionIDs != oldValue else { return }
            persistence.saveLegacyPuckSessionIDs(legacyPuckSessionIDs)
        }
    }
    @Published var isPuckCleanupPresented = false
    /// The command palette's picked agent profile. `nil` is Auto: actions fall
    /// back to their default (e.g. New Session copies the current session).
    /// Persisted in `UserDefaults` so the pick survives relaunches.
    @Published var paletteAgentProfileID: String? {
        didSet {
            if let paletteAgentProfileID {
                UserDefaults.standard.set(
                    paletteAgentProfileID,
                    forKey: Self.paletteAgentProfileDefaultsKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Self.paletteAgentProfileDefaultsKey)
            }
        }
    }
    private static let paletteAgentProfileDefaultsKey = "commandPaletteAgentProfile"
    @Published var sessionLaunchConfigurationDiagnostic: String?
    @Published var paletteCommands: [PaletteCommand] = []
    @Published var paletteConfigurationDiagnostic: String?
    /// The most recent palette command this app ran, so the sidebar can show
    /// that it happened, how it ended, and where its output went. Palette
    /// commands are how sessions get opened for worktrees/verification
    /// (`workit`, `review-linear`), and a failed launch used to be
    /// indistinguishable from a command that did nothing at all.
    @Published var paletteCommandRun: PaletteCommandRun?
    /// The one inbound suggestion waiting on a decision, pushed in through
    /// `POST /suggest`. Nothing in it runs until the human approves it.
    @Published var pendingSuggestion: InboundSuggestion?
    /// Owns the pending slot and the dedup window behind `pendingSuggestion`.
    var suggestionInbox = SuggestionInbox()
    static let projectLaunchDefaultsKey = "projectNewSessionLaunch"
    /// Parents whose children are folded. Persisted in `UserDefaults`; this is
    /// the only child-visibility state, so a parent is either folded or
    /// unfolded, and unfolding shows every child again.
    @Published var foldedParentIDs: Set<String> = [] {
        didSet {
            sidebarGroupsRevision &+= 1
            UserDefaults.standard.set(
                Array(foldedParentIDs),
                forKey: Self.foldedParentsDefaultsKey
            )
        }
    }
    /// Presentation-only scope for the Sessions sidebar. Focus keeps work that
    /// needs a human or has finished; quiet work stays in All sessions without
    /// being paused, suspended, or closed.
    @Published var sidebarScope: SessionSidebarScope = .focus {
        didSet {
            guard sidebarScope != oldValue else { return }
            sidebarGroupsRevision &+= 1
            UserDefaults.standard.set(sidebarScope.rawValue, forKey: Self.sidebarScopeDefaultsKey)
        }
    }
    private static let foldedParentsDefaultsKey = "sidebarFoldedParentIDs"
    private static let legacyCollapsedParentsDefaultsKey = "sidebarCollapsedParentIDs"
    private static let sidebarScopeDefaultsKey = "sidebarScope"

    let codexThreads: CodexThreadCoordinator
    let codexRemote: CodexRemoteControl
    var slackTerminalContext: any TerminalConversationContextReading
    let slackStructuredHistory = SlackStructuredHistory()
    let slackNativeTranscriptHistory = SlackNativeTranscriptHistory()
    let slackThreadJournal: SlackThreadJournal
    let slackDecisionJournal: SlackDecisionJournal
    let slackFollowUpJournal: SlackFollowUpJournal
    let slackAwayJournal: SlackAwayJournal
    lazy var slackIntegration = SlackIntegrationController.live(remote: codexRemote, host: host)
    let slackSessionEventEpoch = UUID().uuidString
    @Published var codexSessionError: String?
    var pendingCodexTUIHandoffs: Set<String> = []
    @Published var codexTUIOwnership: [String: CodexTUIOwnershipObservation] = [:]

    var controlServer: ControlServer?
    let makeControlServer: (SessionStore, HostRuntimeContext) -> ControlServer
    var didStartRuntime = false
    let persistence: any SessionStorePersistenceBackend
    let recentProjectHistory: RecentProjectHistory
    /// Shared memory of `gh` reference lookups, so a click on a `#123` that has
    /// already been resolved does not spend another GitHub API call.
    let githubReferenceCache: GitHubReferenceCache
    /// Serial queue for the SQLite session write, keeping the full-table rewrite off
    /// the main thread. Serial + ordered so concurrent saves can't collide on the
    /// `BEGIN IMMEDIATE` transaction.
    let sessionPersistenceQueue = DispatchQueue(label: "com.banyan.session-persistence", qos: .utility)
    /// Last snapshot set written to disk; lets `saveSessions()` skip the frequent
    /// no-op saves (e.g. every supervisor tick) that re-serialized unchanged state.
    var lastSavedSessionSnapshots: [SessionSnapshot]?
    var lastSavedSnapshotIndexByID: [String: Int] = [:]
    let detector: AgentStateDetector
    /// Internal rather than private so the pane-input routes in
    /// `SessionStore+AgentInput.swift` can hand it to their off-main work.
    let tmuxBackend: any TmuxSessionStoreBackend
    let sessionBackend: any TmuxClientBackend
    let processTable: any ProcessTableProvider
    /// Refuses an answer that the pane has moved past, and one a delivery target
    /// has already had accepted. Main-actor confined, which is what makes
    /// "consumed" a decision and not a race.
    var answerLedger = AgentAnswerLedger()
    /// Status transitions a `/events` long-poll has not read yet.
    var sessionEventLog = SessionEventLog()
    var awayPromptActivationID: String?
    var awayPromptFootprints: [String: String] = [:]
    /// Last status written to the event log per session, so a transition can name
    /// what it came from.
    var lastRecordedEventStatuses: [String: SessionStatus] = [:]
    /// Wakes a parked `/events` request the moment a transition lands, so the
    /// control server never has to poll for one.
    var onSessionEvent: ((SessionEvent) -> Void)?
    let historyBackend: any SessionHistoryBackend
    let attentionNotifier: AttentionNotifier
    var didLoadPersistedSessions = false
    var didAttemptStartupAgentRecovery = false
    var supervisorTimer: Timer?
    var didStartSupervisor = false
    /// Outlives individual ticks so a pane that produced no output since the last
    /// observation is classified from the text already in hand instead of paying
    /// another `tmux capture-pane`. See `SupervisorInspectionCache`.
    let supervisorInspectionCache = SupervisorInspectionCache()
    var supervisorTimerDueAt = Date.distantPast
    var supervisorTimerGeneration = UUID()
    var supervisorScheduledInterval: TimeInterval = 0
    /// Per-session observation state. Quiet sessions back off independently so
    /// one active agent does not force every stale session through tmux on each
    /// global timer fire.
    var supervisorObservationStates: [String: SessionSupervisorObservationState] = [:]
    lazy var supervisorProcessExitMonitor = SupervisorProcessExitMonitor { [weak self] id in
        self?.resetSupervisorObservationBackoff(for: id)
    }
    /// App-lifecycle / thermal / power observers that re-evaluate the supervisor
    /// cadence. Installed once; retained so they outlive `addObserver`.
    var supervisorLifecycleObservers: [NSObjectProtocol] = []
    var supervisorTickSchedule = SessionSupervisorTickSchedule()
    var pendingSupervisorActivityIDs: Set<String> = []
    /// Input, explicit status, and process-exit signals retain the fast response
    /// deadline. Raw PTY traffic alone uses the visibility-aware cadence.
    var pendingSupervisorSignalIDs: Set<String> = []
    /// Watches Codex's session index so a thread renamed mid-conversation
    /// reaches the sidebar without waiting for the next launch.
    var codexTitleWatcher: CodexSessionIndexWatcher?
    /// Watches the agent-list sources (`~/.banyan/config.yml` and
    /// `~/.agents/agents.yml`) so picker edits apply without a restart.
    var launchConfigWatcher: LaunchConfigWatcher?
    var isHistoryImportRunning = false
    var isHistoryImportPending = false
    /// Coalesces the one-shot import requested when a live agent turn starts;
    /// see `scheduleAgentTitleImportIfNeeded`.
    var agentTitleImportTask: Task<Void, Never>?
    /// How long after a turn begins the agent's transcript read waits. Enough
    /// for the prompt to be on disk, short enough that the sidebar titles the
    /// session while the turn is still running.
    static let agentTitleImportDelay: Duration = .seconds(4)
    /// Cap per session so an agent that publishes no transcript at all cannot
    /// turn every later turn into a history scan.
    static let agentTitleImportAttemptLimit = 3
    @Published var pendingRespawnRecoveryIDs = Set<String>()
    /// Sessions whose deleted worktree is being recreated before their attach.
    @Published var pendingWorktreeRecoveryIDs = Set<String>()
    @Published var worktreeRecoveryErrors: [String: WorktreeRecovery.Failure] = [:]
    @Published var historyResumeErrors: [String: String] = [:]
    var latestImportedHistory: [ImportedAgentSession] = []
    /// Transcript parsing is expensive enough to keep off every redraw. The
    /// cache is shared across rows so re-hovering a transcript reuses its
    /// signature and incremental parser state.
    let sessionCostCache = SessionCostCache()
    var sessionCostTranscriptSources: [String: SessionCostTranscriptSource] = [:]
    var lastCodexGeneratedTitles: [String: String] = [:]
    var selectedContextTask: Task<Void, Never>?
    var displayContextRetryTask: Task<Void, Never>?
    var displayContextRetryAttempts = 0
    var selectedContextSignature: String?
    var selectedContextResolvedAt = Date.distantPast
    /// Network/git-derived context keyed by `SessionContextResolver.cacheKey`.
    /// Lets title-text churn and the periodic stale refresh reuse a recent result
    /// instead of re-spawning `git`/`linear`/`gh` on every resolve.
    var selectedContextCache: [String: (info: SessionContextInfo, at: Date)] = [:]
    // Linear titles and PR URLs for a given cwd/issue/PR change rarely, so a long TTL
    // keeps the subprocess-free fast path serving most resolves. At 180s the periodic
    // 30s stale-refresh forced a real `linear`/`gh` resolve every ~3min per selected
    // session; 600s cuts that ~3x while keeping the titlebar acceptably fresh.
    let selectedContextCacheTTL: TimeInterval = 600
    var selectedLinearIssueTask: Task<Void, Never>?
    var selectedGitHubIssueTask: Task<Void, Never>?
    var selectedGitHubIssueURL: URL?
    var selectedLinearIssueStatusTask: Task<Void, Never>?
    var selectedLinearIssueStatusTimer: Timer?
    var selectedLinearIssueStatusRetryAfter = Date.distantPast
    var selectedLinearIssueIdentifier: String?
    var pendingSelectedLinearDescriptionUpdate: PendingLinearDescriptionUpdate?
    var selectedPullRequestTask: Task<Void, Never>?
    var selectedPullRequestPreviewURL: URL?
    var didLoadCachedLinearIssues = false
    var linearIssueListTask: Task<Void, Never>?
    var linearIssueListWatchdogTask: Task<Void, Never>?
    var linearIssueListRequestID = UUID()
    var linearIssueListRefreshTimer: Timer?
    static let linearIssueListRefreshInterval: TimeInterval = 30 * 60
    static let linearIssueListLoadTimeout: TimeInterval = 45
    var branchRefreshTimer: Timer?
    /// Effective cadence the live branch timer was installed with, so a
    /// reschedule that changes nothing is free.
    var currentBranchRefreshInterval: TimeInterval = 0
    var branchRefreshTask: Task<Void, Never>?
    var lastBranchRefreshByCWD: [String: Date] = [:]
    /// Last visibility the periodic work was scheduled for, so coming back from
    /// `.hidden` can force the re-sync that the throttled path skipped.
    var lastObservedActivityLevel: SupervisorActivityLevel = .active
    var lastSuspendedLivenessSweepAt = Date.distantPast
    /// Matches the slowest cadence the supervisor ever backs a quiet live session
    /// off to, so a parked session is never checked more often than a stable one.
    static let suspendedLivenessSweepInterval = SessionSupervisorBackoffPolicy.maxInterval
    /// Ceiling on transcripts inspected when resolving a closed row's agent
    /// session. Each one costs a short head read, and files are visited
    /// newest-first, so this only ever gives up on the oldest conversations —
    /// while keeping the worst case bounded as local history keeps growing.
    nonisolated static let resumeRecoveryFileScanLimit = 20_000
    var selectedLinearListIssueTask: Task<Void, Never>?
    var pendingSelectedLinearListDescriptionUpdate: PendingLinearDescriptionUpdate?
    /// Recently loaded issue details stay available while the user moves
    /// through the Linear list. Re-selecting an issue can render this stale
    /// snapshot immediately while the network refresh runs in the background.
    var linearIssueDetailsCache: [String: LinearIssueDetails] = [:]
    var workspaceSaveTask: Task<Void, Never>?
    var scratchWindow: NSWindow?
    var scratchWindowDelegate: ScratchTerminalWindowDelegate?
    var isClosingScratchTerminal = false
    var cachedSessionSidebarGroups: [SidebarSessionGroup]?
    var cachedSessionSidebarGroupsRevision = -1
    var cachedHiddenSessionCount = 0
    /// Bumped whenever an input to the active sidebar projection changes. The
    /// projection used to hash every active row on every SwiftUI pass; even a
    /// cache hit walked the active set and read every presentation field.
    var sidebarGroupsRevision = 0 { didSet { scheduleWorkSummaryUpdate() } }
    var cachedSidebarHistoryItems: [SidebarSessionItem]?
    /// Bumped whenever a row that is (or was) shown in History changes. The
    /// projection used to hash every persisted session on every SwiftUI pass to
    /// detect that, which made a cache hit O(all history) and dominated the main
    /// thread while switching sessions.
    var sidebarHistoryRevision = 0
    var cachedSidebarHistoryRevision = -1
    var cachedSidebarHistoryFilterText: String?
    /// History rows from the last rebuild. A session that is no longer closed
    /// still needs to invalidate the cached projection (it just left History).
    var sidebarHistorySessionIDs: Set<String> = []
    let host: HostRuntimeContext
    let telemetry: PerformanceTelemetry
    var homeDirectory: String { host.homeDirectory.path }
    var environment: [String: String] { host.environment }
    var currentDirectory: String { host.currentDirectory }

    init(
        persistence: any SessionStorePersistenceBackend,
        tmuxBackend: any TmuxSessionStoreBackend,
        sessionBackend: any TmuxClientBackend,
        processTable: any ProcessTableProvider,
        historyBackend: any SessionHistoryBackend,
        detector: AgentStateDetector,
        host: HostRuntimeContext,
        telemetry: PerformanceTelemetry,
        attentionNotifier: AttentionNotifier,
        puckDaemon: (any PuckDaemonService)? = nil,
        codexService: (any CodexThreadService)? = nil,
        workitPauseClient: (any WorkitPauseClient)? = nil,
        pauseCloseProjectionTimeout: Duration = .seconds(5),
        freezePreferences: UserDefaults = .standard,
        makeControlServer: @escaping (SessionStore, HostRuntimeContext) -> ControlServer = {
            ControlServer(store: $0, host: $1)
        }
    ) {
        self.workitPauseClient = workitPauseClient ?? WorkitCommandPauseClient(host: host)
        self.pauseCloseProjectionTimeout = pauseCloseProjectionTimeout
        self.freezePreferences = freezePreferences
        let storedLimit = freezePreferences.integer(forKey: AgentAdmissionController.defaultsKey)
        let admission = AgentAdmissionController(limit: storedLimit > 0 ? min(AgentAdmissionController.maximumLimit, storedLimit) : AgentAdmissionController.defaultLimit)
        self.agentAdmission = admission
        self.makeControlServer = makeControlServer
        self.codexThreads = CodexThreadCoordinator(service: codexService ?? CodexAppServerClient(environment: host.environment), admission: admission)
        self.codexRemote = CodexRemoteControl(coordinator: codexThreads,
            file: BanyanDataDirectory.url(for: "Banyan/remote/slack.json",
                environment: host.environment, homeDirectory: host.homeDirectory))
        self.slackThreadJournal = SlackThreadJournal(file: BanyanDataDirectory.url(for: "Banyan/remote/slack-threads.json",
            environment: host.environment, homeDirectory: host.homeDirectory))
        self.slackDecisionJournal = SlackDecisionJournal(file: BanyanDataDirectory.url(for: "Banyan/remote/slack-decisions.json",
            environment: host.environment, homeDirectory: host.homeDirectory))
        self.slackFollowUpJournal = SlackFollowUpJournal(file: BanyanDataDirectory.url(for: "Banyan/remote/slack-followups.json",
            environment: host.environment, homeDirectory: host.homeDirectory))
        self.slackAwayJournal = SlackAwayJournal(file: BanyanDataDirectory.url(for: "Banyan/remote/slack-away.json",
            environment: host.environment, homeDirectory: host.homeDirectory))
        self.puckDaemon = puckDaemon ?? PuckDaemonClient(
            environment: host.environment,
            homeDirectory: host.homeDirectory.path
        )
        self.persistence = persistence
        self.recentProjectHistory = RecentProjectHistory(persistence: persistence,
            queue: sessionPersistenceQueue, environment: host.environment, homeDirectory: host.homeDirectory.path)
        self.githubReferenceCache = GitHubReferenceCache(persistence: persistence)
        self.tmuxBackend = tmuxBackend
        self.slackTerminalContext = TerminalConversationContextReader(backend: tmuxBackend, inspector: CodexTUIProcessInspector(),
            generations: SlackConversationGenerationTracker(file: BanyanDataDirectory.url(for: "Banyan/remote/slack-generations.json",
                environment: host.environment, homeDirectory: host.homeDirectory)))
        self.sessionBackend = sessionBackend
        self.processTable = processTable
        self.historyBackend = historyBackend
        self.detector = detector
        self.host = host
        self.telemetry = telemetry
        self.attentionNotifier = attentionNotifier
        maximumConcurrentAgents = admission.limit
        admission.onChange = { [weak self] in self?.publishAgentAdmission() }
        codexThreads.sessionTitleServer = { id in
            guard AgentSessionTitleLaunch.isEnabled(environment: host.environment),
                  let executable = AgentProcessHost.executableURL(environment: host.environment),
                  let data = try? JSONSerialization.data(withJSONObject: AgentSessionTitleLaunch.codexServerConfiguration(
                    sessionID: id, executable: executable.path, environment: host.environment)) else { return nil }
            return try? JSONDecoder().decode(CodexJSONValue.self, from: data)
        }
        codexThreads.onChange = { [weak self] id, state in
            guard let self, let session = self.sessions.first(where: { $0.id == id }) as? CodexSession else { return }
            session.apply(state)
            self.saveChangedSession(session)
        }
        codexThreads.onEvent = { [weak self] id, method, params in
            (self?.sessions.first(where: { $0.id == id }) as? CodexSession)?.receive(method: method, params: params)
        }
        codexThreads.onHydrate = { [weak self] id, thread in
            (self?.sessions.first(where: { $0.id == id }) as? CodexSession)?.hydrate(thread: thread)
        }
        codexThreads.flushPersistence = { [weak self] in
            guard let queue = self?.sessionPersistenceQueue else { return }
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
        codexRemote.metadata = { [weak self] id in
            guard let session = self?.sessions.first(where: { $0.id == id }) as? CodexSession else { return nil }
            return (session.displayTitle, session.cwd)
        }
        codexRemote.externalThreadAvailable = { [weak self] sessionID, threadID, principal, slackThread in
            guard let self else { return false }
            return (try? self.slackThreadJournal.permitsNativeAttachment(sessionID: sessionID, threadID: threadID,
                principal: principal, slackThread: slackThread)) == true
        }
        codexRemote.recentConversation = { [weak self] id in
            (self?.sessions.first(where: { $0.id == id }) as? CodexSession)?.conversation
        }
        codexRemote.onChange = { [weak self] in
            guard let self else { return }
            try? self.slackAwayJournal.resetIfChannelRemoved(allowed: self.codexRemote.policy.allowed)
            self.slackIntegration.policyChanged()
            for case let session as CodexSession in self.sessions {
                session.remoteStatus = self.codexRemote.desktopStatus(sessionID: session.id)
            }
        }
        let defaults = UserDefaults.standard
        autoFreezeAgents = freezePreferences.bool(forKey: "autoFreezeAgents")
        if let minutes = freezePreferences.object(forKey: "agentFreezeIdleMinutes") as? Double {
            agentFreezeIdleMinutes = min(120, max(1, minutes.isFinite ? minutes : 10))
        }
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
                terminalFontSize: defaultFontSize,
                enableCodexAppServerMode: false,
                sessionRetentionDays: SessionRetentionPolicy.defaultRetentionDays,
                enableHandoffAction: false
            )
        )
        selectedSessionID = workspace.selectedSessionID
        sortMode = workspace.sortMode
        terminalTheme = workspace.terminalTheme
        terminalFontFamily = workspace.terminalFontFamily
        terminalFontSize = workspace.terminalFontSize
        enableCodexAppServerMode = workspace.enableCodexAppServerMode
        autoRetryCodexFailures = workspace.autoRetryCodexFailures
        enableNativeCodex = workspace.enableNativeCodex
        enableHandoffAction = workspace.enableHandoffAction
        codexThreads.isEnabled = enableNativeCodex
        sessionRetentionDays = SessionRetentionPolicy.normalizedRetentionDays(workspace.sessionRetentionDays)
        terminalRenderer = TerminalRendererPreference.resolvedDefault
        if let stored = defaults.dictionary(forKey: Self.projectLaunchDefaultsKey) as? [String: String] {
            projectLaunchByGroup = stored
        }
        paletteAgentProfileID = defaults.string(forKey: Self.paletteAgentProfileDefaultsKey)
        if let folded = defaults.array(forKey: Self.foldedParentsDefaultsKey) as? [String] {
            foldedParentIDs = Set(folded)
        } else if let collapsed = defaults.array(forKey: Self.legacyCollapsedParentsDefaultsKey) as? [String] {
            foldedParentIDs = Set(collapsed)
        }
        sidebarScope = defaults.string(forKey: Self.sidebarScopeDefaultsKey)
            .flatMap(SessionSidebarScope.init(rawValue:)) ?? .focus
        let launchConfiguration = SessionLaunchProfileLoader.load(
            homeDirectory: host.homeDirectory
        )
        sessionLaunchProfiles = launchConfiguration.profiles
        sessionLaunchConfigurationDiagnostic = launchConfiguration.diagnostic
        let shortcutConfiguration = SessionShortcutConfiguration.load(homeDirectory: host.homeDirectory)
        sessionShortcutConfiguration = shortcutConfiguration.configuration
        sessionShortcutConfigurationDiagnostic = shortcutConfiguration.diagnostic
        coercePaletteAgentProfile()
        let paletteConfiguration = PaletteCommandLoader.load(
            homeDirectory: host.homeDirectory
        )
        paletteCommands = paletteConfiguration.commands
        paletteConfigurationDiagnostic = paletteConfiguration.diagnostic
        refreshHandoffAvailability()

        selection.bind(to: self)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSessionSaves()
            self?.flushPendingTelemetry()
        }

        installLinearIssueListRefreshTimer()
        installLaunchConfigWatcher()
    }
}
