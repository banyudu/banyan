import BanyanCore
import Foundation

enum PuckFollowState: Equatable {
    /// Not on screen, so not connected.
    case stopped
    /// Attaching and replaying the transcript.
    case connecting
    /// Attached; new events arrive as the daemon emits them.
    case following
    /// The stream ended while the session was on screen: the daemon went
    /// away or dropped the connection.
    case lost
}

/// A session that lives in the local `puckd`.
///
/// The daemon owns the agent loop, its transcript, and its approvals, and
/// shares them with other frontends such as Slack. This object mirrors the
/// daemon's summary into the shared session state, and follows the event
/// stream while the session is on screen. Closing it in Banyan only stops
/// following it: the daemon keeps the durable session, so it can be reopened.
@MainActor
final class PuckSession: BanyanSession {
    @Published private(set) var binding: PuckSessionBinding
    /// The daemon's own word for where the session is: `idle`, `running`,
    /// `parked`, `interrupted`, or `hibernated`.
    @Published private(set) var position: String?
    @Published private(set) var pendingApproval: PuckPendingApproval?
    @Published private(set) var pendingQuestion: PuckPendingQuestion?
    @Published private(set) var questionPlan: String?
    /// The replayed and live transcript, held only while the session is followed.
    @Published private(set) var events: [PuckSessionEvent] = []
    @Published private(set) var historyItems: [PuckHistoryItem] = []
    @Published private(set) var nextHistoryCursor: String?
    @Published private(set) var historyLoading = false
    private var historyWindow = PuckHistoryWindow()
    private var viewingOlderHistory = false
    private static var historyOwners: [String: WeakHistoryOwner] = [:]
    private static let globalHistoryBytes = 4 * 1_048_576
    private final class WeakHistoryOwner {
        weak var value: PuckSession?
        var used = Date()
        init(_ value: PuckSession) { self.value = value }
    }
    @Published private(set) var followState: PuckFollowState = .stopped
    /// The last daemon failure: unreachable, or a rejected request.
    @Published var daemonError: String?
    @Published private(set) var cancelInFlight = false
    @Published private(set) var decisionInFlight = false
    @Published private(set) var answerInFlight = false
    /// A dismissible status line: an accepted cancel (the session and its
    /// history remain), a compaction, or `/status` output.
    @Published var infoNotice: String?
    /// Images attached to the next message.
    @Published var draftImages: [PuckDraftImage] = []
    /// Messages typed while a turn was busy, sent in order once it settles.
    @Published var queuedPrompts: [PuckQueuedPrompt] = []
    /// The daemon's reported features, fetched when the session is followed.
    @Published var daemonCapabilities: PuckCapabilities?
    /// When the current turn was first seen running, for the elapsed timer.
    @Published var turnStartedAt: Date?
    /// Esc in the composer moves the keyboard to a pending ask.
    @Published var askFocusRequest = 0
    @Published var compactInFlight = false
    var compactAccepted = false
    /// Set while a queued message is being handed to the daemon, so two
    /// summaries arriving together cannot start it twice.
    var queueDispatchInFlight = false
    /// A user-requested stop returns queued messages to the composer instead
    /// of sending them into the next turn.
    var restoreQueueOnStop = false

    let daemon: any PuckDaemonService
    /// The daemon's latest word on this session, kept so a reopen can restore
    /// the status it describes without waiting for the next listing.
    private var lastSummary: PuckSessionSummary?
    /// `codex` or `native`, from the daemon's summary once one has arrived.
    var engine: String { lastSummary?.engine ?? (binding.provider == "codex" ? "codex" : "native") }
    private var followTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var followGeneration = 0
    @Published private(set) var admissionTurnInFlight = false
    @Published var draft = ""
    /// The user's own message while the daemon has not echoed it yet. Native
    /// engine sessions only publish the prompt with the turn's history at
    /// completion, so waiting for `puckd` would hide the row for the whole
    /// response. The row is withdrawn once the canonical copy arrives.
    private struct OptimisticPrompt: Identifiable, Equatable {
        let id: String
        let text: String
        let images: [String]
        /// Matching user rows already visible when this prompt was submitted.
        /// Comparing counts keeps repeated prompts distinct from older ones.
        let canonicalCount: Int
    }
    @Published private var optimisticPrompts: [OptimisticPrompt] = []
    var onAdmissionTurnStarting: (() -> Void)?
    var onPendingChangedWithoutStatusTransition: (() -> Void)?
    private var summaryRevision = 0
    private var resolvedApprovalCallID: String?
    private var resolvedQuestionCallID: String?

    deinit { followTask?.cancel(); historyTask?.cancel() }

    private var canonicalTimeline: PuckTimeline {
        PuckTimelineProjection.project(history: historyItems, events: events)
    }

    var timeline: PuckTimeline {
        let canonical = canonicalTimeline
        let counts = Self.userMessageCounts(in: canonical)
        let pending = optimisticPrompts.filter {
            counts[$0.text, default: 0] <= $0.canonicalCount
        }
        guard !pending.isEmpty else { return canonical }
        return PuckTimeline(
            items: canonical.items + pending.map { prompt in
                PuckTimelineItem(
                    id: "optimistic:\(prompt.id)",
                    role: .user,
                    content: .user(prompt.text),
                    images: prompt.images
                )
            },
            notices: canonical.notices,
            usage: canonical.usage,
            activity: canonical.activity
        )
    }

    private static func normalizedUserText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func userMessageCounts(in timeline: PuckTimeline) -> [String: Int] {
        timeline.items.reduce(into: [:]) { counts, item in
            guard item.role == .user else { return }
            counts[normalizedUserText(item.text), default: 0] += 1
        }
    }

    @discardableResult
    private func showOptimisticPrompt(_ text: String, images: [String] = []) -> String {
        let id = UUID().uuidString.lowercased()
        let pendingCopies = optimisticPrompts.filter { $0.text == text }.count
        let count = Self.userMessageCounts(in: canonicalTimeline)[text, default: 0] + pendingCopies
        optimisticPrompts.append(OptimisticPrompt(id: id, text: text, images: images, canonicalCount: count))
        return id
    }

    private func withdrawOptimisticPrompt(_ id: String) {
        optimisticPrompts.removeAll { $0.id == id }
    }

    private func reconcileOptimisticPrompts() {
        guard !optimisticPrompts.isEmpty else { return }
        let counts = Self.userMessageCounts(in: canonicalTimeline)
        optimisticPrompts.removeAll { counts[$0.text, default: 0] > $0.canonicalCount }
    }

    private var cachedBytes: Int {
        historyWindow.byteCount + events.reduce(0) { $0 + $1.retainedByteCount }
    }
    private func enforceHistoryBudget() {
        while events.count > 200 || cachedBytes > 2 * 1_048_576 {
            guard !events.isEmpty else { break }; events.removeFirst()
        }
        Self.historyOwners = Self.historyOwners.filter { $0.value.value != nil }
        if Self.historyOwners[id]?.value !== self { Self.historyOwners[id] = WeakHistoryOwner(self) }
        Self.historyOwners[id]?.used = Date()
        while Self.historyOwners.values.compactMap(\.value).reduce(0, { $0 + $1.cachedBytes }) > Self.globalHistoryBytes {
            guard let victim = Self.historyOwners.filter({ $0.key != id }).min(by: { $0.value.used < $1.value.used }) else { break }
            victim.value.value?.clearHistoryCache()
            Self.historyOwners.removeValue(forKey: victim.key)
        }
    }
    private func clearHistoryCache() {
        events = []; historyWindow.clear(); historyItems = []; nextHistoryCursor = nil
    }
    private func discardHistoryCache() {
        clearHistoryCache()
        optimisticPrompts = []
        Self.historyOwners.removeValue(forKey: id)
    }
    func loadOlderHistory() {
        guard let cursor = nextHistoryCursor, !historyLoading, followState != .stopped else { return }
        historyLoading = true; viewingOlderHistory = true
        let daemon = self.daemon; let id = self.id; let generation = followGeneration
        historyTask = Task {
            defer { if followGeneration == generation { historyLoading = false; historyTask = nil } }
            do {
                let page = try await PuckBackgroundIO.run { try daemon.history(id, cursor: cursor, limit: 50) }
                guard followGeneration == generation, followState != .stopped, !Task.isCancelled else { return }
                historyWindow.merge(page, older: true); historyItems = historyWindow.items
                nextHistoryCursor = page.nextCursor; enforceHistoryBudget()
                reconcileOptimisticPrompts()
            } catch { daemonError = error.localizedDescription }
        }
    }
    func loadLatestHistory() {
        guard !historyLoading, followState != .stopped else { return }
        historyLoading = true; viewingOlderHistory = false
        let daemon = self.daemon; let id = self.id; let generation = followGeneration
        historyTask = Task {
            defer { if followGeneration == generation { historyLoading = false; historyTask = nil } }
            do {
                let page = try await PuckBackgroundIO.run { try daemon.history(id, cursor: nil, limit: 50) }
                guard followGeneration == generation, followState != .stopped, !Task.isCancelled else { return }
                historyWindow.replace(with: page); historyItems = historyWindow.items
                nextHistoryCursor = page.nextCursor; events = []; enforceHistoryBudget()
                reconcileOptimisticPrompts()
            } catch { daemonError = error.localizedDescription }
        }
    }

    /// Why the daemon would refuse a new turn now, or `nil` when it takes one.
    /// Mirrors `puckd`'s own preconditions, so the UI can say so up front.
    var turnUnavailableReason: String? {
        if pendingApproval != nil || pendingQuestion != nil {
            return "Answer the pending ask before sending a new message."
        }
        if position == "running" {
            return "Stop the running turn before sending a new message."
        }
        if position == "parked" {
            return "Stop the parked turn before sending a new message."
        }
        return nil
    }

    init(
        id: String,
        binding: PuckSessionBinding,
        title: String,
        titleURL: String? = nil,
        titleURLWasAutoDetected: Bool? = nil,
        reportedTitle: String? = nil,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        status: SessionStatus = .idle,
        tone: SessionTone = .neutral,
        parentSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isSuspended: Bool = false,
        displayContext: SessionProjectContext? = nil,
        daemon: any PuckDaemonService,
        telemetry: PerformanceTelemetry,
        host: HostRuntimeContext,
        githubReferenceCache: GitHubReferenceCache? = nil
    ) {
        self.binding = binding
        self.daemon = daemon
        super.init(
            id: id,
            title: title,
            titleURL: titleURL,
            titleURLWasAutoDetected: titleURLWasAutoDetected,
            generatedTitle: generatedTitle,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            // A daemon session runs no command Banyan could replay.
            command: "",
            status: status,
            tone: tone,
            parentSessionID: parentSessionID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isSuspended: isSuspended,
            displayContext: displayContext,
            agentProvider: binding.agentProvider,
            agentModelID: binding.model,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )
        self.reportedTitle = reportedTitle
        refreshGeneratedTitle()
    }

    // MARK: - Backend interface

    override var backendKind: SessionBackendKind { .puck }

    override var puckBinding: PuckSessionBinding? { binding }

    /// Daemon IDs are UUIDs, which would otherwise become the title. A generic
    /// seed titles a fresh session the way a fresh terminal agent is titled
    /// ("Codex session") until its first prompt names it.
    override var titleSeed: String { "session" }

    override var closeEndsAgentWork: Bool { false }

    override var backingSessionName: String { "puck session" }

    override var closeConsequence: String {
        "Closing \(displayTitle) removes it from the sidebar. Its puck session stays in puckd and can be reopened."
    }

    override func siblingLaunch(profiles: [NewSessionLaunch], codexLaunchMode: CodexLaunchMode) -> SessionLaunchSpec {
        .puck(binding)
    }

    override func matchesLaunchProfile(_ profile: NewSessionLaunch) -> Bool {
        guard let launch = profile.puck, launch.provider == binding.provider else { return false }
        // An unspecified model or account in the profile lets the daemon pick,
        // so it describes any session on that provider.
        return (launch.model == nil || launch.model == binding.model)
            && (launch.account == nil || launch.account == binding.account)
    }

    override func closeBackingSession() {
        stopFollowing(retainHistory: false)
        super.closeBackingSession()
    }

    override func terminate(markClosed: Bool = true) {
        stopFollowing(retainHistory: false)
        super.terminate(markClosed: markClosed)
    }

    override func suspend() {
        guard status != .closed, !isSuspended else { return }
        stopFollowing(retainHistory: false)
        super.suspend()
    }

    // MARK: - Daemon state

    /// Mirrors one daemon summary into the shared session state.
    func apply(summary: PuckSessionSummary) {
        let previousApproval = pendingApproval, previousQuestion = pendingQuestion
        summaryRevision += 1
        lastSummary = summary
        daemonError = nil
        let reported = PuckSessionBinding(summary: summary)
        if reported != binding {
            binding = reported
            markDetectedAgentProvider(reported.agentProvider)
        }
        markDetectedAgentModel(reported.model, isExact: true)
        position = summary.position
        if let resolvedApprovalCallID, summary.pendingApproval?.callID == resolvedApprovalCallID {
            pendingApproval = nil
        } else {
            self.resolvedApprovalCallID = nil
            pendingApproval = summary.pendingApproval
        }
        let priorQuestion = pendingQuestion?.callID
        if let resolvedQuestionCallID, summary.pendingQuestion?.callID == resolvedQuestionCallID {
            pendingQuestion = nil
        } else {
            self.resolvedQuestionCallID = nil
            pendingQuestion = summary.pendingQuestion
        }
        if pendingQuestion?.callID != priorQuestion {
            questionPlan = nil
            if let callID = pendingQuestion?.callID {
                let daemon = self.daemon
                let id = self.id
                Task { [weak self] in
                    do {
                        let plan = try await PuckBackgroundIO.run { try daemon.plan(id) }
                        guard let self, self.pendingQuestion?.callID == callID else { return }
                        self.questionPlan = plan
                    } catch {
                        guard let self, self.pendingQuestion?.callID == callID else { return }
                        self.daemonError = error.localizedDescription
                    }
                }
            }
        }
        reconcileAdmissionFromSummary()
        noteTurnActivity()
        dispatchQueuedPromptIfReady()
        // A closed row stays closed until the user reopens it, and a parked one
        // keeps what it last showed: Banyan was asked to stop watching both.
        guard status != .closed, !isSuspended else { return }
        let next = PuckSessionStatusPolicy.status(for: summary)
        if next != status {
            mark(status: next, tone: PuckSessionStatusPolicy.tone(for: next))
        } else if previousApproval != pendingApproval || previousQuestion != pendingQuestion {
            onPendingChangedWithoutStatusTransition?()
        }
    }

    private func reconcileAdmissionFromSummary() {
        guard let summary = lastSummary else { return }
        if summary.position == "running" || summary.position == "parked" || summary.pendingApproval != nil || summary.pendingQuestion != nil {
            if agentAdmission?.running.contains(id) != true { agentAdmission?.adopt(id) }
        } else if !admissionTurnInFlight && ["idle", "interrupted", "hibernated"].contains(summary.position) {
            agentAdmission?.release(id)
        }
    }

    /// Brings a closed session back into the working set. Its status is the
    /// daemon's, so the store refreshes it right after.
    func reopen() {
        guard status == .closed else { return }
        isSuspended = false
        let reopened = lastSummary.map(PuckSessionStatusPolicy.status(for:)) ?? .idle
        mark(status: reopened, tone: PuckSessionStatusPolicy.tone(for: reopened))
    }

    func noteDaemonError(_ message: String) {
        daemonError = message
    }

    // MARK: - Following

    /// Replays the transcript and follows new events while the session is on
    /// screen. The previous transcript stays visible until that replay arrives,
    /// so switching back does not flash an empty loading state. Sidebar state
    /// comes from the store's shared watch connection.
    func startFollowing() {
        guard status != .closed, !isSuspended else { return }
        if followState == .lost { followTask?.cancel(); followTask = nil }
        guard followTask == nil else { return }
        followGeneration += 1
        let generation = followGeneration
        viewingOlderHistory = false
        daemonError = nil
        followState = .connecting
        refreshDaemonCapabilities()
        let daemon = self.daemon
        let id = self.id
        followTask = Task { [weak self] in
            var delay: UInt64 = 1
            var reattaching = false
            while !Task.isCancelled {
                do {
                    for try await update in daemon.follow(id) {
                        guard let self, self.followGeneration == generation, !Task.isCancelled else { return }
                        if reattaching {
                            // The daemon that answered may be a new build
                            // (a local deploy restarts it), with new features.
                            reattaching = false
                            self.refreshDaemonCapabilities()
                        }
                        self.receive(update)
                        delay = 1
                    }
                } catch {
                    guard let self, self.followGeneration == generation else { return }
                    self.daemonError = error.localizedDescription
                }
                guard let self, self.followGeneration == generation else { return }
                self.followState = .lost
                // Recovery backoff, not an idle-session polling loop. The
                // next attach replays durable cursors before receiving live data.
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                catch { return }
                guard self.followGeneration == generation else { return }
                self.followState = .connecting
                reattaching = true
                delay = min(delay * 2, 30)
            }
        }
    }

    /// Detaches this client. A running turn continues in the daemon. The
    /// bounded cache remains available for a quick switch back and is evicted
    /// by the shared history budget as other sessions are viewed.
    func stopFollowing(retainHistory: Bool = true) {
        followGeneration += 1
        followTask?.cancel()
        followTask = nil
        historyTask?.cancel(); historyTask = nil; historyLoading = false
        followState = .stopped
        if retainHistory {
            enforceHistoryBudget()
        } else {
            discardHistoryCache()
        }
    }

    private func receive(_ update: PuckSessionUpdate) {
        switch update {
        case .attached(let summary, let replayed):
            events = replayed
            followState = .following
            apply(summary: summary)
        case .events(let next):
            // The daemon cursor is authoritative. Replayed and live events meet
            // at this boundary without duplicate rows.
            let last = events.last?.cursor ?? 0
            events.append(contentsOf: next.filter { $0.transient || $0.cursor > last })
        case .history(let page):
            if !viewingOlderHistory {
                historyWindow.replace(with: page); historyItems = historyWindow.items
                nextHistoryCursor = page.nextCursor; events = []
            }
        case .summary(let summary):
            apply(summary: summary)
        }
        enforceHistoryBudget()
        reconcileOptimisticPrompts()
    }

    // MARK: - Input

    /// Starts a turn, or queues the message while one is busy. The first
    /// prompt names an untitled session, as it does a terminal agent.
    /// The draft's attachments go only where its text names them, renumbered
    /// from `[Image #1]`.
    func send(_ prompt: String) {
        let message = PuckImagePlaceholders.normalized(
            text: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            images: draftImages
        )
        guard !message.text.isEmpty else { return }
        if draft == prompt { draft = "" }
        draftImages = []
        PuckDraftImage.discardStaged(message.unused)
        let prompt = PuckQueuedPrompt(text: message.text, images: message.images)
        if isBusyForNewTurn {
            queuedPrompts.append(prompt)
            return
        }
        dispatch(prompt, restoreToDraftOnRejection: true)
    }

    /// Hands one message to the daemon. A definite rejection puts it back
    /// where it came from: the composer, or the head of the queue.
    func dispatch(_ prompt: PuckQueuedPrompt, restoreToDraftOnRejection: Bool) {
        let optimisticID = showOptimisticPrompt(prompt.text, images: prompt.images.map(\.path))
        Task { [weak self] in
            do {
                try await self?.startTurn(prompt.text, images: prompt.images.map(\.path))
                PuckDraftImage.discardStaged(prompt.images)
            } catch {
                guard let self else { return }
                self.daemonError = error.localizedDescription
                if Self.definitelyRejected(error) {
                    self.withdrawOptimisticPrompt(optimisticID)
                    if restoreToDraftOnRejection, self.draft.isEmpty {
                        self.replaceDraft(text: prompt.text, images: prompt.images)
                    } else if !restoreToDraftOnRejection {
                        self.queuedPrompts.insert(prompt, at: 0)
                    }
                }
            }
            self?.queueDispatchInFlight = false
            self?.dispatchQueuedPromptIfReady()
        }
    }

    private static func definitelyRejected(_ error: Error) -> Bool {
        if error is CancellationError || error is ControlError { return true }
        guard let daemonError = error as? PuckDaemonError else { return false }
        switch daemonError {
        case .rejected, .server, .notSubmitted: return true
        case .unavailable, .invalidResponse: return false
        }
    }

    func startTurn(_ prompt: String, images: [String] = [], authorization: (() throws -> Void)? = nil,
                   willSubmit: (() throws -> Void)? = nil,
                   mayDispatch: @escaping @Sendable () -> Bool = { true }) async throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        infoNotice = nil
        guard !admissionTurnInFlight else { throw ControlError.badRequest("A turn is already starting for this session") }
        admissionTurnInFlight = true
        var accepted = false
        var sent = false
        var definiteRejection = false
        var reconciledAfterResponse = false
        defer {
            admissionTurnInFlight = false
            if reconciledAfterResponse { reconcileAdmissionFromSummary() }
            else if !accepted && (!sent || definiteRejection) {
                reconcileAdmissionFromSummary()
                if lastSummary == nil { agentAdmission?.release(id) }
            }
        }
        onAdmissionTurnStarting?()
        try await agentAdmission?.acquire(id)
        try Task.checkCancellation()
        try authorization?()
        guard turnUnavailableReason == nil else { throw ControlError.badRequest(turnUnavailableReason!) }
        try willSubmit?()
        if !text.isEmpty { markSubmittedPromptTitle(text) }
        let daemon = self.daemon
        let id = self.id
        sent = true
        do {
            try await PuckBackgroundIO.run {
                guard mayDispatch() else { throw PuckDaemonError.rejected("Remote authorization changed before dispatch") }
                try daemon.turn(id, prompt: text, images: images)
            }
        } catch {
            if error is CancellationError { definiteRejection = true }
            if let daemonError = error as? PuckDaemonError {
                switch daemonError {
                case .rejected, .server, .notSubmitted: definiteRejection = true
                default: break
                }
            }
            throw error
        }
        accepted = true
        // A short turn can finish before turn() returns. Query after the ACK,
        // keeping its slot during the query and respecting a newer watch update.
        let revision = summaryRevision
        do {
            let summary = try await PuckBackgroundIO.run { try daemon.get(id) }
            if summaryRevision == revision { apply(summary: summary) }
            reconciledAfterResponse = true
        } catch {
            // A dropped response cannot establish exit. The dashboard watch or
            // a later catalog reconciliation resolves the reservation.
            daemonError = error.localizedDescription
        }
        if reconciledAfterResponse { return }
        // Running is known the moment the daemon accepts the turn; the event
        // stream and the next listing confirm it.
        guard status != .closed, !isSuspended, status != .executing else { return }
        if turnStartedAt == nil { turnStartedAt = Date() }
        mark(status: .executing, tone: .blue)
    }

    func decide(_ decision: String, reason: String? = nil, afterDecision: (() -> Void)? = nil) {
        guard let pending = pendingApproval, !decisionInFlight else { return }
        decisionInFlight = true
        daemonError = nil
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            defer { self?.decisionInFlight = false }
            do {
                try await PuckBackgroundIO.run {
                    try daemon.decide(id, callID: pending.callID, decision: decision, reason: reason)
                }
                guard let self else { return }
                self.acknowledgeApproval(pending.callID)
                afterDecision?()
                let summary = try await PuckBackgroundIO.run { try daemon.get(id) }
                self.apply(summary: summary)
            } catch {
                self?.daemonError = error.localizedDescription
            }
        }
    }

    /// Stops the active turn through puckd. Cancelling a turn is not closing
    /// the session: its transcript and history stay durable and the following
    /// connection remains attached.
    func cancel(restoringQueue: Bool = true) {
        guard turnPhase.isTurnActive, !cancelInFlight else { return }
        cancelInFlight = true
        restoreQueueOnStop = restoringQueue && !queuedPrompts.isEmpty
        infoNotice = nil
        daemonError = nil
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            defer {
                self?.cancelInFlight = false
                self?.dispatchQueuedPromptIfReady()
            }
            do {
                try await PuckBackgroundIO.run { try daemon.cancel(id) }
                let summary = try await PuckBackgroundIO.run { try daemon.get(id) }
                guard let self else { return }
                self.apply(summary: summary)
                if !self.turnPhase.isTurnActive {
                    self.infoNotice = "Turn stopped. This session and its history remain available."
                }
            } catch {
                self?.restoreQueueOnStop = false
                self?.daemonError = error.localizedDescription
            }
        }
    }

    func answer(_ selections: [PuckQuestionSelection]) {
        guard let pending = pendingQuestion, !answerInFlight else { return }
        answerInFlight = true
        daemonError = nil
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            defer { self?.answerInFlight = false }
            do {
                try await PuckBackgroundIO.run {
                    try daemon.answer(id, callID: pending.callID, selections: selections)
                }
                guard let self else { return }
                self.acknowledgeQuestion(pending.callID)
                let summary = try await PuckBackgroundIO.run { try daemon.get(id) }
                self.apply(summary: summary)
            } catch {
                self?.daemonError = error.localizedDescription
            }
        }
    }

    private func acknowledgeApproval(_ callID: String) {
        guard pendingApproval?.callID == callID else { return }
        pendingApproval = nil
        resolvedApprovalCallID = callID
        if status != .closed, !isSuspended { onPendingChangedWithoutStatusTransition?() }
    }

    private func acknowledgeQuestion(_ callID: String) {
        guard pendingQuestion?.callID == callID else { return }
        pendingQuestion = nil
        questionPlan = nil
        resolvedQuestionCallID = callID
        if status != .closed, !isSuspended { onPendingChangedWithoutStatusTransition?() }
    }
}
