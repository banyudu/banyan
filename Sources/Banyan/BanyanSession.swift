import AppKit
import BanyanCore
import Foundation

/// One Banyan session: a sidebar row with a title, status, project, and place
/// in the session tree, whatever runs behind it.
///
/// The sidebar, selection, shortcuts, attention navigation, and persistence all
/// work on this class. Subclasses own the backing work: `TerminalSession` runs
/// a command in tmux and renders it with SwiftTerm, and `PuckSession` follows a
/// durable `puckd` session. The members under "Backend interface" are what
/// differs between them; code outside the subclasses reaches for a concrete
/// type only for work that exists on one backend alone.
@MainActor
class BanyanSession: ObservableObject, Identifiable {
    let id: String
    let createdAt: Date
    let historyTranscriptURL: URL?

    var displayProject: String
    var displayBranch: String?
    var displayIsGitWorktree: Bool
    var displayIsDefaultBranch: Bool
    /// `true` when the last git lookup for the fields above failed to run (timed
    /// out / couldn't launch) rather than answering. Those readings are then
    /// unreliable false-negatives, so we retry on later ticks until we get a
    /// trustworthy one. See `updateDisplayContext` / `retryDisplayContextIfDegraded`.
    var displayContextDegraded: Bool
    @Published var projectGroupID: String
    @Published var projectGroupTitle: String

    var projectName: String {
        displayProject
    }

    @Published var title: String
    @Published var titleURL: String?
    @Published var reportedTitle: String?
    @Published var generatedTitle: String?
    @Published var detectedAgentProvider: CodingAgentProvider?
    /// Runtime model identity. A terminal OpenCode session learns it from the
    /// supervisor and clears it when the process exits; a puck session reads it
    /// from its daemon. Deliberately not persisted.
    @Published var detectedAgentModelID: String?
    @Published var detectedAgentModelIDIsExact = false
    @Published var isTitlePinned: Bool
    @Published var cwd: String
    @Published var command: String
    @Published var status: SessionStatus
    @Published var tone: SessionTone
    @Published var updatedAt: Date
    @Published var isRestored: Bool
    @Published var isProcessStarted: Bool
    /// Persisted metadata can outlive the dedicated tmux session after reboot.
    @Published var needsRecovery: Bool
    /// Parked out of Banyan's working set. Deliberately orthogonal to `status`:
    /// the backing session and its agent are untouched, so the row keeps the
    /// last observed agent state and resuming restores it instead of resetting
    /// it. See `suspend()` / `resume()`.
    @Published var isSuspended: Bool
    /// Actual agent process-group STOP, independent of frontend parking.
    @Published var agentQueuePosition: Int?
    @Published var agentLaunchQueue: AgentLaunchQueueState?
    var agentAdmission: AgentAdmissionController?
    @Published var isFrozen = false
    @Published var isDeepSuspended = false
    @Published var isDeepResuming = false
    @Published var isDeepTerminating = false
    @Published var parentSessionID: String?
    /// Underlying coding-agent session UUID (codex/claude), resolved by matching
    /// live sessions against imported transcript history. Used to build a resume
    /// command when a closed session is reopened, instead of replaying the
    /// original launch command from scratch.
    @Published var agentSessionID: String?
    var lastConversationResetAt: Date?

    let telemetry: PerformanceTelemetry
    let homeDirectory: String
    let environment: [String: String]
    /// Remembers `gh` reference lookups so repeated clicks do not spend GitHub
    /// rate limit. Sessions are built by `SessionStore`, which owns the cache;
    /// a nil cache simply means every click asks.
    let githubReferenceCache: GitHubReferenceCache?

    // MARK: - Presentation memoization
    //
    // `displayTitle` and `titleLinkLabel` are pure functions of the fields below, but
    // both are expensive (path canonicalization, command tokenizing, regex matching)
    // and the sidebar evaluates them for every session on every pass — measured at
    // ~1,200 and ~1,000 calls per pass across 734 sessions. Caching the result against
    // its inputs turns all but the first into a handful of string comparisons.
    //
    // `homeDirectory` and `environment` are `let`, so they are deliberately absent from
    // both keys. Every other input is listed; anything added to the policy calls in
    // BanyanSession+Presentation.swift must be added to the matching key too, or the
    // cache will serve a stale value.
    struct DisplayTitleKey: Equatable {
        let title: String
        let isTitlePinned: Bool
        let reportedTitle: String?
        let generatedTitle: String?
        let cwd: String
        let detectedProvider: CodingAgentProvider?
        let command: String
    }

    struct TitleLinkLabelKey: Equatable {
        let titleURL: String?
        let title: String
        let displayBranch: String?
        let displayIsGitWorktree: Bool
        let cwd: String
    }

    /// Resolving a provider tokenizes the command line, which made
    /// `CodingAgentProvider.shellTokens` the hottest single frame on the main thread.
    /// The sidebar's history filter asks every session for its provider on every pass,
    /// so this is evaluated far more often than either title.
    struct AgentProviderKey: Equatable {
        let command: String
        let detectedProvider: CodingAgentProvider?
    }

    struct DisplayAgentProviderKey: Equatable {
        let status: SessionStatus
        let command: String
        let detectedProvider: CodingAgentProvider?
    }

    /// How many provider-history imports this session has asked for while
    /// looking for its transcript. Bounds the cost for an agent that publishes
    /// no transcript at all; reset whenever one is matched.
    var agentTitleImportAttempts = 0
    var displayTitleCache: (key: DisplayTitleKey, value: String)?
    var titleLinkLabelCache: (key: TitleLinkLabelKey, value: String?)?
    var agentProviderCache: (key: AgentProviderKey, value: CodingAgentProvider?)?
    var displayAgentProviderCache: (key: DisplayAgentProviderKey, value: CodingAgentProvider?)?

    var onDidChange: (() -> Void)?
    var onOutput: ((String) -> Void)?
    /// Called after the user submits input. SessionStore uses this to wake
    /// supervision for commands launched from an initially plain shell.
    var onUserSubmittedInput: ((String?) -> Void)?
    var onStatusSignal: ((SessionStatus) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?
    var onProjectContextObserved: ((String, SessionProjectContext) -> Void)?
    var externalTitleSignature: String?
    var externalTitleTask: Task<Void, Never>?
    var titleURLWasAutoDetected = false
    /// Generation counter for async directory updates. OSC7 directory
    /// notifications arrive on the main thread during streaming output; the git
    /// lookups they need must run in the background. Rapid `cd`s bump this so
    /// a stale background lookup cannot clobber a newer directory.
    var directoryUpdateGeneration = 0

    init(
        id: String,
        title: String,
        titleURL: String? = nil,
        titleURLWasAutoDetected: Bool? = nil,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        command: String,
        status: SessionStatus = .running,
        tone: SessionTone = .blue,
        parentSessionID: String? = nil,
        agentSessionID: String? = nil,
        historyTranscriptURL: URL? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isRestored: Bool = false,
        needsRecovery: Bool = false,
        isSuspended: Bool = false,
        displayContext: SessionProjectContext? = nil,
        agentProvider: CodingAgentProvider? = nil,
        agentModelID: String? = nil,
        telemetry: PerformanceTelemetry,
        host: HostRuntimeContext,
        githubReferenceCache: GitHubReferenceCache? = nil
    ) {
        self.telemetry = telemetry
        self.homeDirectory = host.homeDirectory.path
        self.environment = host.environment
        self.githubReferenceCache = githubReferenceCache
        let resolvedDisplayContext = displayContext ?? SessionDisplayLabel.cachedContext(
            cwd: cwd,
            homeDirectory: self.homeDirectory,
            environment: self.environment
        )
        self.id = id
        self.historyTranscriptURL = historyTranscriptURL
        self.title = title
        let detectedReference = LinearIssueReference.detect(
            branch: resolvedDisplayContext.branch,
            cwd: cwd,
            isGitWorktree: resolvedDisplayContext.isGitWorktree,
            environment: environment
        )
        if let normalizedTitleURL = SessionInputPolicy.normalizedTitleURL(titleURL) {
            // A restore passes the persisted provenance. Without one (a fresh spawn),
            // infer it: a URL that matches what the cwd/branch says is auto-detected,
            // and anything else was chosen deliberately by the caller.
            let wasAutoDetected = titleURLWasAutoDetected
                ?? (normalizedTitleURL == detectedReference?.url)
            if wasAutoDetected && !resolvedDisplayContext.gitLookupDegraded
                && !(isRestored && status == .closed) {
                // Repository-derived bindings describe the current checkout, not a
                // permanent choice. Reconcile persisted rows immediately so a branch
                // switched while Banyan was stopped cannot revive a stale issue chip.
                self.titleURL = detectedReference?.url
                self.titleURLWasAutoDetected = detectedReference != nil
            } else {
                self.titleURL = normalizedTitleURL
                self.titleURLWasAutoDetected = wasAutoDetected
            }
        } else {
            self.titleURL = detectedReference?.url
            self.titleURLWasAutoDetected = detectedReference != nil
        }
        self.generatedTitle = generatedTitle
        // Recover the launched identity synchronously. A terminal session reads
        // it from its persisted command: a restored/recovered session starts in
        // `.running` before the supervisor has had a chance to inspect its process
        // tree, and leaving this nil makes the sidebar render every agent as a
        // plain terminal during that window. Other backends know it outright.
        self.detectedAgentProvider = agentProvider ?? CodingAgentProvider.detect(in: command)
        self.detectedAgentModelID = agentModelID
        self.detectedAgentModelIDIsExact = agentModelID != nil
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.command = command
        self.displayProject = resolvedDisplayContext.project
        self.displayBranch = resolvedDisplayContext.branch
        self.displayIsGitWorktree = resolvedDisplayContext.isGitWorktree
        self.displayIsDefaultBranch = resolvedDisplayContext.isDefaultBranch
        self.displayContextDegraded = resolvedDisplayContext.gitLookupDegraded
        self.projectGroupID = resolvedDisplayContext.groupID
        self.projectGroupTitle = resolvedDisplayContext.groupTitle
        self.status = status
        self.tone = tone
        self.parentSessionID = parentSessionID
        self.agentSessionID = agentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isRestored = isRestored
        self.needsRecovery = needsRecovery
        self.isSuspended = isSuspended
        // A freshly spawned background session has no backing yet. Keep this
        // false until the backend confirms it; otherwise the supervisor can race
        // the async creation, observe a missing session, and mark the row
        // closed before the command ever starts.
        self.isProcessStarted = false
    }

    // MARK: - Backend interface

    /// Which runtime owns the session.
    var backendKind: SessionBackendKind {
        preconditionFailure("\(type(of: self)) must override backendKind")
    }

    /// The tmux session a terminal row persists. `nil` for other backends.
    var persistedTmuxSessionName: String? { nil }

    /// The daemon runtime a puck row persists. `nil` for other backends.
    var puckBinding: PuckSessionBinding? { nil }
    var codexBinding: CodexThreadBinding? { nil }

    /// Seeds the automatic title before the agent or a prompt names the
    /// session. A terminal session's ID is usually a readable name
    /// (`codex-2`); a backend with opaque IDs substitutes a generic one.
    var titleSeed: String { id }

    /// Whether a restart means anything: it re-runs the launch command.
    var canRestart: Bool { false }

    /// Whether closing ends the agent's work. Closing always asks first; this
    /// decides whether the confirmation also warns that a process dies.
    var closeEndsAgentWork: Bool { true }

    /// What keeps running behind the row, for text that names it.
    var backingSessionName: String { "backing session" }

    /// What closing does to the backing session, for the close confirmation.
    var closeConsequence: String {
        "Closing \(displayTitle) ends the session."
    }

    /// Whether provider transcripts on disk (Codex, Claude, OpenCode) title and
    /// resume this session. Only a terminal agent writes them; a daemon keeps
    /// its own transcript.
    var matchesAgentTranscripts: Bool { false }

    /// What a new session "like this one" launches, for Cmd+N and the palette.
    func siblingLaunch(profiles: [NewSessionLaunch], codexLaunchMode: CodexLaunchMode) -> SessionLaunchSpec {
        .terminal(command: "")
    }

    /// Whether `profile` describes how this session was launched, so its row
    /// can carry the profile's icon.
    func matchesLaunchProfile(_ profile: NewSessionLaunch) -> Bool { false }

    /// Starts the backing work without showing it, for a background spawn.
    func startBackgroundBackendIfNeeded() {}

    /// Ends the session in Banyan and releases what backs it.
    func closeBackingSession() {
        agentAdmission?.cancel(id)
        status = .closed
        isSuspended = false
        touch()
    }

    /// Stops observing the session without touching the backing work.
    func terminate(markClosed: Bool = true) {
        if markClosed {
            status = .closed
            // A closed session is over, not parked. Leaving the flag set would
            // badge a history row and carry parking into a later reopen.
            isSuspended = false
        }
        touch()
    }

    /// Parks the session: Banyan stops observing and rendering it while the
    /// backing session keeps running untouched, so `resume()` is lossless.
    ///
    /// `status` is deliberately left alone. It still describes the agent, which
    /// is still doing whatever it was doing; overwriting it here would lose
    /// exactly the state a resume is supposed to bring back.
    func suspend() {
        guard !isImportedHistory, status != .closed, !isSuspended else { return }
        agentAdmission?.cancel(id)
        isSuspended = true
        touch()
    }

    /// Returns the session to Banyan's working set.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        touch()
    }

    /// Applies the terminal appearance, for backends that render a terminal.
    func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13, force: Bool = false) {}

    func apply(renderer: TerminalRendererPreference) {}

    /// Shows a notice where the user will see it when the session is opened.
    func feedOrQueue(_ text: String) {}

    func touch() {
        // `updatedAt` feeds sidebar ordering and the sidebar/history cache
        // hashes, which scan every row (~3000 with closed history). Bumping it
        // on every observation and output chunk kept those caches permanently
        // cold: each keystroke re-evaluates the menu bar, which rebuilds the
        // full grouping. Recency at 2s granularity is plenty for
        // human-readable ordering and resume heuristics.
        let now = Date()
        if now.timeIntervalSince(updatedAt) >= 2 {
            updatedAt = now
        }
        onDidChange?()
    }
}
