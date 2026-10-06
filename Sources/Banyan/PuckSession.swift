import BanyanCore
import Foundation

/// Where this client stands with a puck session's event stream.
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
    @Published private(set) var followState: PuckFollowState = .stopped
    /// The last daemon failure: unreachable, or a rejected request.
    @Published private(set) var daemonError: String?

    let daemon: any PuckDaemonService
    /// The daemon's latest word on this session, kept so a reopen can restore
    /// the status it describes without waiting for the next listing.
    private var lastSummary: PuckSessionSummary?
    private var followTask: Task<Void, Never>?
    private var followGeneration = 0

    deinit { followTask?.cancel() }

    var renderedEvents: [PuckRenderedEvent] { PuckTranscript.render(events) }

    /// Why the daemon would refuse a new turn now, or `nil` when it takes one.
    /// Mirrors `puckd`'s own preconditions, so the UI can say so up front.
    var turnUnavailableReason: String? {
        if pendingApproval != nil || pendingQuestion != nil || position == "parked" {
            return "Answer the pending ask before sending a new message."
        }
        if position == "running" {
            return "Wait for the running turn to finish."
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
        stopFollowing()
        super.closeBackingSession()
    }

    override func terminate(markClosed: Bool = true) {
        stopFollowing()
        super.terminate(markClosed: markClosed)
    }

    override func suspend() {
        guard status != .closed, !isSuspended else { return }
        stopFollowing()
        super.suspend()
    }

    // MARK: - Daemon state

    /// Mirrors one daemon summary into the shared session state.
    func apply(summary: PuckSessionSummary) {
        lastSummary = summary
        daemonError = nil
        let reported = PuckSessionBinding(summary: summary)
        if reported != binding {
            binding = reported
            markDetectedAgentProvider(reported.agentProvider)
        }
        markDetectedAgentModel(reported.model, isExact: true)
        position = summary.position
        pendingApproval = summary.pendingApproval
        let priorQuestion = pendingQuestion?.callID
        pendingQuestion = summary.pendingQuestion
        if pendingQuestion?.callID != priorQuestion {
            questionPlan = nil
            if let callID = pendingQuestion?.callID {
                let daemon = self.daemon
                let id = self.id
                Task { [weak self] in
                    do {
                        let plan = try await Task.detached(priority: .utility) { try daemon.plan(id) }.value
                        guard let self, self.pendingQuestion?.callID == callID else { return }
                        self.questionPlan = plan
                    } catch {
                        guard let self, self.pendingQuestion?.callID == callID else { return }
                        self.daemonError = error.localizedDescription
                    }
                }
            }
        }
        // A closed row stays closed until the user reopens it, and a parked one
        // keeps what it last showed: Banyan was asked to stop watching both.
        guard status != .closed, !isSuspended else { return }
        let next = PuckSessionStatusPolicy.status(for: summary)
        guard next != status else { return }
        mark(status: next, tone: PuckSessionStatusPolicy.tone(for: next))
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
    /// screen. Sidebar state comes from the store's shared watch connection.
    func startFollowing() {
        guard status != .closed, !isSuspended else { return }
        if followState == .lost { followTask?.cancel(); followTask = nil }
        guard followTask == nil else { return }
        followGeneration += 1
        let generation = followGeneration
        events = []
        daemonError = nil
        followState = .connecting
        let daemon = self.daemon
        let id = self.id
        followTask = Task { [weak self] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    for try await update in daemon.follow(id) {
                        guard let self, self.followGeneration == generation, !Task.isCancelled else { return }
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
                delay = min(delay * 2, 30)
            }
        }
    }

    /// Detaches this client. A running turn continues in the daemon.
    func stopFollowing() {
        followGeneration += 1
        followTask?.cancel()
        followTask = nil
        followState = .stopped
        events = []
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
            events.append(contentsOf: next.filter { $0.cursor > last })
        case .summary(let summary):
            apply(summary: summary)
        }
    }

    // MARK: - Input

    /// Starts a turn. The first prompt names an untitled session, as it does a
    /// terminal agent.
    func send(_ prompt: String) {
        Task { [weak self] in
            do {
                try await self?.startTurn(prompt)
            } catch {
                self?.daemonError = error.localizedDescription
            }
        }
    }

    func startTurn(_ prompt: String) async throws {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        markSubmittedPromptTitle(text)
        let daemon = self.daemon
        let id = self.id
        try await Task.detached(priority: .userInitiated) {
            try daemon.turn(id, prompt: text)
        }.value
        // Running is known the moment the daemon accepts the turn; the event
        // stream and the next listing confirm it.
        guard status != .closed, !isSuspended, status != .executing else { return }
        mark(status: .executing, tone: .blue)
    }

    func decide(_ decision: String) {
        guard let pending = pendingApproval else { return }
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try daemon.decide(id, callID: pending.callID, decision: decision)
                    return try daemon.get(id)
                }.value
                self?.apply(summary: summary)
            } catch {
                self?.daemonError = error.localizedDescription
            }
        }
    }

    func answer(_ selections: [PuckQuestionSelection]) {
        guard let pending = pendingQuestion else { return }
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try daemon.answer(id, callID: pending.callID, selections: selections)
                    return try daemon.get(id)
                }.value
                self?.apply(summary: summary)
            } catch {
                self?.daemonError = error.localizedDescription
            }
        }
    }
}
