import AppKit
import BanyanCore
import Foundation
import SwiftTerm

@MainActor
final class BanyanSession: ObservableObject, Identifiable {
    let id: String
    let tmuxSessionName: String
    let createdAt: Date
    let historyTranscriptURL: URL?

    private var _terminalView: DetectingLocalProcessTerminalView?

    /// The SwiftTerm view backing this session, created on first access.
    ///
    /// A terminal preallocates its scrollback eagerly (~4.7 MB here), so building
    /// one per session in `init` cost ~1.7 GB across a restored workspace: every
    /// persisted row gets a `BanyanSession`, and the overwhelming majority are
    /// closed history entries that are never opened (only `historySidebarBrowseLimit`
    /// of them are even browsable). Allocating on demand keeps the cost proportional
    /// to the terminals actually shown. Use `loadedTerminalView` from paths that must
    /// not bring one into existence.
    var terminalView: DetectingLocalProcessTerminalView {
        if let _terminalView {
            return _terminalView
        }
        let view = makeTerminalView()
        _terminalView = view
        return view
    }

    /// Non-allocating peek at the terminal. `nil` until something actually needs to
    /// display or run this session, which lets repaint and teardown paths no-op
    /// instead of materializing a terminal just to tear it down.
    var loadedTerminalView: DetectingLocalProcessTerminalView? {
        _terminalView
    }
    private var displayProject: String
    private var displayBranch: String?
    private var displayIsGitWorktree: Bool
    private var displayIsDefaultBranch: Bool
    /// `true` when the last git lookup for the fields above failed to run (timed
    /// out / couldn't launch) rather than answering. Those readings are then
    /// unreliable false-negatives, so we retry on later ticks until we get a
    /// trustworthy one. See `updateDisplayContext` / `retryDisplayContextIfDegraded`.
    private var displayContextDegraded: Bool
    @Published private(set) var projectGroupID: String
    @Published private(set) var projectGroupTitle: String

    var projectName: String {
        displayProject
    }

    @Published var title: String
    @Published var titleURL: String?
    @Published var reportedTitle: String?
    @Published var generatedTitle: String?
    @Published var detectedAgentProvider: CodingAgentProvider?
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
    @Published var parentSessionID: String?
    /// Underlying coding-agent session UUID (codex/claude), resolved by matching
    /// live sessions against imported transcript history. Used to build a resume
    /// command when a closed session is reopened, instead of replaying the
    /// original launch command from scratch.
    @Published var agentSessionID: String?
    private(set) var lastConversationResetAt: Date?

    private var delegate: TerminalSessionDelegate?
    private let tmuxBackend = TmuxBackend.shared
    var onDidChange: (() -> Void)?
    var onOutput: ((String) -> Void)?
    var onStatusSignal: ((SessionStatus) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?
    var onProjectContextObserved: ((String, SessionProjectContext) -> Void)?
    private var didRenderRestoredMessage = false
    private var appliedTheme: TerminalTheme?
    private var appliedFontFamily: String?
    private var appliedFontSize: Double?
    /// Desired appearance, tracked even while no terminal exists so one created
    /// later comes up already styled rather than flashing an unthemed frame.
    private var pendingTheme: TerminalTheme
    private var pendingFontFamily: String?
    private var pendingFontSize: Double
    private var pendingTerminalMessage: String?
    private var externalTitleSignature: String?
    private var externalTitleTask: Task<Void, Never>?
    private var isDetachingTerminalClient = false
    private var attemptedBlankTerminalRecovery = false
    private(set) var titleURLWasAutoDetected = false
    private var terminalRefreshTask: Task<Void, Never>?

    var displayTitle: String {
        if hasUsefulPinnedTitle {
            return title
        }

        if agentProvider != nil, let agentTitle = usefulAgentTitle {
            return agentTitle
        }

        if let generatedTitle = generatedTitle.flatMap(SessionTitleGenerator.sanitizeTitle) {
            return generatedTitle
        }

        return title
    }

    /// `titleURL` comes first because the sidebar renders this as the label of a link
    /// *to* that URL: reading the ID off a title from an earlier chapter would show
    /// one issue and open another. The title and cwd only fill in when nothing is bound.
    var titleLinkLabel: String? {
        LinearIssueReference.issueID(in: titleURL)
            ?? LinearIssueReference.issueID(in: title)
            ?? LinearIssueReference.detect(branch: displayBranch, cwd: cwd)?.id
    }

    var agentProvider: CodingAgentProvider? {
        CodingAgentProvider.detect(in: command) ?? detectedAgentProvider
    }

    /// Provider to show in the live sidebar row. Normally the launched identity,
    /// but once the agent process exits the supervisor reports a bare-shell
    /// `.running` pane — then this drops to nil so the row renders like a plain
    /// shell instead of a stale agent (no provider icon, no idle-agent affordances).
    /// `agentProvider` (the launched identity) is intentionally left intact so
    /// reopen/resume still know what this session was. A live agent is never
    /// `.running` (the supervisor only emits it when no agent process is alive), so
    /// this never hides the icon for a genuinely running agent.
    var displayAgentProvider: CodingAgentProvider? {
        if status == .running, CodingAgentProvider.detect(in: command) != nil {
            return nil
        }
        return agentProvider
    }

    var needsManualAttach: Bool {
        isRestored && !isProcessStarted && (status == .failed || needsRecovery)
    }

    var isImportedHistory: Bool {
        historyTranscriptURL != nil
    }

    var canDispatchHandoff: Bool {
        guard !isImportedHistory,
              agentProvider != nil,
              status.isCodingAgentIdle,
              displayIsGitWorktree,
              let branch = displayBranch,
              !displayIsDefaultBranch else {
            return false
        }
        return branch != "main" && branch != "master"
    }

    init(
        id: String,
        tmuxSessionName: String? = nil,
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
        displayContext: SessionProjectContext? = nil,
        theme: TerminalTheme,
        fontFamily: String? = nil,
        fontSize: Double = 13
    ) {
        let resolvedDisplayContext = displayContext ?? SessionDisplayLabel.context(cwd: cwd)
        self.id = id
        self.tmuxSessionName = tmuxSessionName ?? TmuxBackend.sessionName(for: id)
        self.historyTranscriptURL = historyTranscriptURL
        self.title = title
        let detectedReference = LinearIssueReference.detect(branch: resolvedDisplayContext.branch, cwd: cwd)
        if let normalizedTitleURL = Self.normalizedTitleURL(titleURL) {
            // A restore passes the persisted provenance. Without one (a fresh spawn),
            // infer it: a URL that matches what the cwd/branch says is auto-detected,
            // and anything else was chosen deliberately by the caller.
            let wasAutoDetected = titleURLWasAutoDetected
                ?? (normalizedTitleURL == detectedReference?.url)
            if wasAutoDetected && !resolvedDisplayContext.gitLookupDegraded {
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
        self.detectedAgentProvider = nil
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
        // A freshly spawned background session has no tmux backing yet. Keep this
        // false until ensureSession succeeds; otherwise the supervisor can race
        // the async tmux creation, observe a missing session, and mark the row
        // closed before the command ever starts.
        self.isProcessStarted = false
        self.pendingTheme = theme
        self.pendingFontFamily = fontFamily
        self.pendingFontSize = fontSize

        let delegate = TerminalSessionDelegate(sessionID: id)
        delegate.onTitle = { [weak self] title in
            guard let self else { return }
            self.reportedTitle = title
            self.refreshGeneratedTitle()
            self.touch()
        }
        delegate.onDirectoryChange = { [weak self] directory in
            self?.updateCurrentDirectory(directory)
        }
        delegate.onTerminate = { [weak self] exitCode in
            guard let self else { return }
            self.isProcessStarted = false
            if self.isDetachingTerminalClient {
                self.isDetachingTerminalClient = false
                self.touch()
                return
            }
            if self.status != .closed, let onProcessExit = self.onProcessExit {
                onProcessExit(exitCode)
                return
            }
            if self.status != .closed, self.tmuxBackend.hasSession(named: self.tmuxSessionName) {
                self.status = .running
            } else if self.status != .closed {
                self.status = exitCode == 0 ? .completed : .failed
                self.onStatusSignal?(self.status)
            }
            self.touch()
        }
        self.delegate = delegate

        refreshGeneratedTitle()
    }

    private func makeTerminalView() -> DetectingLocalProcessTerminalView {
        let view = DetectingLocalProcessTerminalView(frame: .zero)
        view.tmuxSessionName = tmuxSessionName
        pendingTheme.apply(to: view, fontFamily: pendingFontFamily, fontSize: pendingFontSize)
        appliedTheme = pendingTheme
        appliedFontFamily = pendingFontFamily
        appliedFontSize = pendingFontSize
        view.processDelegate = delegate
        view.onOutput = { [weak self] text in
            self?.onOutput?(text)
        }
        if let pendingTerminalMessage {
            view.feed(text: pendingTerminalMessage)
            self.pendingTerminalMessage = nil
        }
        return view
    }

    /// Writes to the terminal if one exists, otherwise holds the text until one is
    /// created. A background start can fail before any terminal is allocated, and
    /// that diagnostic still needs to be there when the session is later opened.
    private func feedOrQueue(_ text: String) {
        if let terminalView = loadedTerminalView {
            terminalView.feed(text: text)
        } else {
            pendingTerminalMessage = (pendingTerminalMessage ?? "") + text
        }
    }

    func renderRestoredMessageIfNeeded(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        guard needsManualAttach, !didRenderRestoredMessage else { return }
        // Only meaningful once the terminal is on screen, which means it already exists.
        guard let terminalView = loadedTerminalView else { return }
        guard terminalView.bounds.width > 80, terminalView.bounds.height > 80 else { return }
        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)
        terminalView.resizeSubviews(withOldSize: .zero)
        terminalView.feed(text: restoredMessage())
        didRenderRestoredMessage = true
    }

    func start() {
        guard !isImportedHistory else { return }
        guard !terminalView.process.running else { return }
        isDetachingTerminalClient = false
        let startedAt = DispatchTime.now()
        startTerminalClient()
        PerformanceTelemetry.shared.recordDuration(
            "terminal.start_client",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
    }

    /// Start the tmux backing (and its launch command) without attaching a visible
    /// terminal client, so a session spawned in the background actually runs without
    /// stealing selection/focus. When the session is later selected, `start()` attaches
    /// the visible client to this already-running tmux session (`ensureSession` is idempotent).
    func startBackgroundBackendIfNeeded() {
        guard !isImportedHistory, status != .closed else { return }
        // Deliberately does not attach a visible client, so it must not create a
        // terminal either — an absent one is by definition not running.
        guard !isProcessStarted, loadedTerminalView?.process.running != true else { return }
        // Optimistically mark running so the sidebar updates immediately; the actual
        // tmux work (subprocess spawns) runs off the main thread to avoid freezing the
        // UI while a session is created via banyanctl.
        isRestored = false
        status = .running
        touch()
        let backend = tmuxBackend
        let name = tmuxSessionName
        let workingDirectory = cwd
        let launchCommand = command
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try backend.ensureSession(named: name, cwd: workingDirectory, command: launchCommand)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isProcessStarted = true
                    self.touch()
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { [weak self] in self?.failToStart(message) }
            }
        }
    }

    func refreshTerminalClient(immediately: Bool = false) {
        guard !isImportedHistory, loadedTerminalView?.process.running == true else { return }
        let tmuxBackend = tmuxBackend
        let tmuxSessionName = tmuxSessionName
        let sessionID = id

        if immediately {
            let startedAt = DispatchTime.now()
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                tmuxBackend.refreshClients(attachedTo: tmuxSessionName)
                PerformanceTelemetry.shared.recordDuration(
                    "tmux.refresh_clients",
                    durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                    sessionID: sessionID,
                    detail: "tmux=\(tmuxSessionName) immediate"
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isImportedHistory,
                          let terminalView = self.loadedTerminalView,
                          terminalView.process.running else { return }
                    terminalView.needsDisplay = true
                    terminalView.setNeedsDisplay(terminalView.bounds)
                }
            }
            return
        }

        terminalRefreshTask?.cancel()
        terminalRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            let startedAt = DispatchTime.now()
            await Task.detached(priority: .utility) {
                tmuxBackend.refreshClients(attachedTo: tmuxSessionName)
            }.value
            PerformanceTelemetry.shared.recordDuration(
                "tmux.refresh_clients",
                durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
                sessionID: sessionID,
                detail: "tmux=\(tmuxSessionName)"
            )
            guard let self,
                  !Task.isCancelled,
                  !self.isImportedHistory,
                  let terminalView = self.loadedTerminalView,
                  terminalView.process.running else {
                return
            }
            terminalView.needsDisplay = true
            terminalView.setNeedsDisplay(terminalView.bounds)
            self.terminalRefreshTask = nil
        }
    }

    func recoverBlankTerminalClientIfNeeded() {
        guard !isImportedHistory,
              !attemptedBlankTerminalRecovery,
              let terminalView = loadedTerminalView,
              terminalView.process.running,
              terminalView.hasVisibleText == false else {
            return
        }
        let capturedText = tmuxBackend.captureCurrentVisibleText(paneID: tmuxSessionName)
        guard capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        PerformanceTelemetry.shared.recordDuration(
            "terminal.blank_recovery",
            durationMS: 1,
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
        attemptedBlankTerminalRecovery = true
        reattachTerminalClient(resetBlankRecoveryAttempt: false)
    }

    func reattachTerminalClient(resetBlankRecoveryAttempt: Bool = true) {
        guard !isImportedHistory else { return }
        let startedAt = DispatchTime.now()
        terminalRefreshTask?.cancel()
        if terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        isProcessStarted = false
        isRestored = false
        terminalView.resetForNewProcess()
        startTerminalClient(resetBlankRecoveryAttempt: resetBlankRecoveryAttempt)
        PerformanceTelemetry.shared.recordDuration(
            "terminal.reattach_client",
            durationMS: PerformanceTelemetry.elapsedMS(since: startedAt),
            sessionID: id,
            detail: "tmux=\(tmuxSessionName)"
        )
    }

    /// Starts a session whose tmux server disappeared while Banyan was stopped.
    /// The caller may supply a provider-specific resume command.
    func recoverFromMissingBackingSession(command recoveryCommand: String? = nil) {
        guard !isImportedHistory else { return }
        if let recoveryCommand, !recoveryCommand.isEmpty {
            command = recoveryCommand
        }
        needsRecovery = false
        isRestored = false
        reattachTerminalClient()
    }

    /// Recreates the backing tmux session without allocating or attaching a
    /// visible terminal client. Used for automatic launch recovery so every
    /// session resumes in the background while only the selected session is
    /// rendered by the UI.
    func recoverFromMissingBackingSessionInBackground(command recoveryCommand: String? = nil) {
        guard !isImportedHistory, !isProcessStarted else { return }
        if let recoveryCommand, !recoveryCommand.isEmpty {
            command = recoveryCommand
        }
        needsRecovery = false
        isRestored = false
        status = .running
        touch()

        let backend = tmuxBackend
        let name = tmuxSessionName
        let workingDirectory = cwd
        let launchCommand = command
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try backend.ensureSession(named: name, cwd: workingDirectory, command: launchCommand)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isProcessStarted = true
                    self.touch()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.failToStart(error.localizedDescription)
                }
            }
        }
    }

    func restartBackingSession() {
        guard !isImportedHistory else { return }
        terminalRefreshTask?.cancel()
        if let terminalView = loadedTerminalView {
            if terminalView.process.running {
                isDetachingTerminalClient = true
            }
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        tmuxBackend.killSession(named: tmuxSessionName)
        isProcessStarted = false
        isRestored = false
        startTerminalClient()
    }

    private func startTerminalClient(resetBlankRecoveryAttempt: Bool = true) {
        do {
            try tmuxBackend.ensureSession(named: tmuxSessionName, cwd: cwd, command: command)
        } catch {
            failToStart(error.localizedDescription)
            return
        }
        isRestored = false
        isProcessStarted = true
        if resetBlankRecoveryAttempt {
            attemptedBlankTerminalRecovery = false
        }
        status = .running
        terminalView.startProcess(
            executable: "/usr/bin/env",
            args: ["-u", "TMUX", "-u", "TMUX_PANE", tmuxBackend.executableURL.path] + tmuxBackend.attachArguments(for: tmuxSessionName),
            environment: Self.terminalEnvironment(),
            currentDirectory: cwd
        )
        touch()
    }

    func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        guard appliedTheme != theme || appliedFontFamily != fontFamily || appliedFontSize != fontSize else {
            return
        }
        pendingTheme = theme
        pendingFontFamily = fontFamily
        pendingFontSize = fontSize
        // A theme change for a session with no terminal yet is just bookkeeping;
        // `makeTerminalView` applies it if and when one is created.
        guard let view = loadedTerminalView else { return }
        theme.apply(to: view, fontFamily: fontFamily, fontSize: fontSize)
        appliedTheme = theme
        appliedFontFamily = fontFamily
        appliedFontSize = fontSize
        view.needsDisplay = true
    }

    func mark(status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil, titleURL: String? = nil) {
        if let status {
            let changed = self.status != status
            self.status = status
            if changed {
                onStatusSignal?(status)
            }
        }
        if let tone {
            self.tone = tone
        }
        if let title, !title.isEmpty {
            self.title = title
            isTitlePinned = true
        }
        if let titleURL {
            self.titleURL = Self.normalizedTitleURL(titleURL)
            titleURLWasAutoDetected = false
        }
        refreshGeneratedTitle()
        touch()
    }

    func markDetectedAgentProvider(_ provider: CodingAgentProvider?) {
        guard detectedAgentProvider != provider else { return }
        detectedAgentProvider = provider
        refreshGeneratedTitle()
        touch()
    }

    func markAgentSessionID(_ sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty, agentSessionID != sessionID else { return }
        agentSessionID = sessionID
        touch()
    }

    func noteUserSubmittedInput(_ submittedInput: String? = nil) {
        if Self.isConversationResetCommand(submittedInput), agentProvider != nil {
            lastConversationResetAt = Date()
            if !hasUsefulPinnedTitle {
                reportedTitle = nil
                generatedTitle = nil
                externalTitleSignature = nil
            }
            touch()
        } else {
            markSubmittedPromptTitle(submittedInput)
        }
        guard !isImportedHistory, isProcessStarted, status != .closed, agentProvider != nil else { return }
        guard [.running, .longRunningShell, .needInput, .asking].contains(status) else { return }
        mark(status: .executing, tone: .blue)
    }

    /// Drop a stale title when the agent transcript shows the current segment
    /// was reset (/clear or /new) with no prompt since. Mirrors the reset
    /// branch of `noteUserSubmittedInput`, but is driven by transcript
    /// observation rather than keystroke capture, so it also fires for resets
    /// the keystroke monitor never saw. Idempotent and pin-safe.
    func noteConversationResetFromTranscript() {
        guard !hasUsefulPinnedTitle else { return }
        guard reportedTitle != nil || generatedTitle != nil || externalTitleSignature != nil else { return }
        reportedTitle = nil
        generatedTitle = nil
        externalTitleSignature = nil
        touch()
    }

    func markFirstPromptTitle(_ title: String) {
        guard !hasUsefulPinnedTitle else { return }
        guard let provider = agentProvider, [.claude, .codex].contains(provider) else { return }
        guard let promptTitle = SessionTitleGenerator.titleFromPrompt(title) else { return }
        guard reportedTitle != promptTitle else { return }
        reportedTitle = promptTitle
        refreshGeneratedTitle()
        touch()
    }

    private func markSubmittedPromptTitle(_ submittedInput: String?) {
        guard !hasUsefulPinnedTitle, usefulAgentTitle == nil, agentProvider != nil else { return }
        guard let promptTitle = Self.submittedPromptTitle(from: submittedInput) else { return }
        reportedTitle = promptTitle
        refreshGeneratedTitle()
        touch()
    }

    func updateCurrentDirectory(_ directory: String?) {
        guard let directory = Self.normalizedDirectory(directory) else { return }
        let displayContext = SessionDisplayLabel.context(cwd: directory)
        guard directory != cwd else {
            applyProjectContext(displayContext)
            if !displayContext.gitLookupDegraded {
                onProjectContextObserved?(directory, displayContext)
            }
            return
        }
        let shouldUpdateTitle = Self.titleTracksCurrentDirectory(title, isTitlePinned: isTitlePinned, cwd: cwd)
        cwd = directory
        updateDisplayContext(displayContext)
        if shouldUpdateTitle {
            title = Self.titleForCurrentDirectory(directory)
        }
        refreshAutoDetectedTitleURL()
        refreshGeneratedTitle()
        touch()
        if !displayContext.gitLookupDegraded {
            onProjectContextObserved?(directory, displayContext)
        }
    }

    /// Apply one repository lookup to this session. SessionStore shares the same
    /// result with sibling panes in this directory so a branch switch updates every
    /// affected row without running duplicate git commands per session.
    func applyProjectContext(_ displayContext: SessionProjectContext) {
        let previousProject = displayProject
        let previousBranch = displayBranch
        let previousIsGitWorktree = displayIsGitWorktree
        let previousIsDefaultBranch = displayIsDefaultBranch
        let previousGroupID = projectGroupID
        let previousGroupTitle = projectGroupTitle
        let previousDegraded = displayContextDegraded
        let previousTitleURL = titleURL
        updateDisplayContext(displayContext)
        refreshAutoDetectedTitleURL()
        let contextChanged = previousProject != displayProject
            || previousBranch != displayBranch
            || previousIsGitWorktree != displayIsGitWorktree
            || previousIsDefaultBranch != displayIsDefaultBranch
            || previousGroupID != projectGroupID
            || previousGroupTitle != projectGroupTitle
            || previousDegraded != displayContextDegraded
        guard contextChanged || titleURL != previousTitleURL else { return }
        refreshGeneratedTitle()
        touch()
    }

    nonisolated static func titleTracksCurrentDirectory(_ title: String, isTitlePinned: Bool, cwd: String) -> Bool {
        guard !isTitlePinned else { return false }
        let currentTitle = SessionTitleGenerator.sanitizeTitle(title)
        let directoryTitle = SessionTitleGenerator.sanitizeTitle(titleForCurrentDirectory(cwd))
        return currentTitle == directoryTitle
    }

    private var usefulAgentTitle: String? {
        guard let value = reportedTitle.flatMap(SessionTitleGenerator.sanitizeTitle), !value.isEmpty else {
            return nil
        }
        guard SessionTitleGenerator.isUsefulTitle(value) else {
            return nil
        }
        return value
    }

    private var hasUsefulPinnedTitle: Bool {
        guard isTitlePinned else { return false }
        let cleanedTitle = SessionTitleGenerator.sanitizeTitle(title) ?? ""
        guard SessionTitleGenerator.isUsefulTitle(cleanedTitle) else { return false }
        let defaultTitle = PathDisplayName.make(path: cwd)
        return cleanedTitle != defaultTitle
    }

    private func refreshGeneratedTitle() {
        guard !hasUsefulPinnedTitle else { return }
        guard agentProvider != nil else {
            generatedTitle = nil
            return
        }
        let titleCommand = lastConversationResetAt == nil
            ? command
            : (agentProvider?.defaultExecutableName ?? command)
        let context = SessionTitleContext(
            id: id,
            baseTitle: title,
            isTitlePinned: hasUsefulPinnedTitle,
            cwd: cwd,
            project: displayProject,
            branch: displayBranch,
            command: titleCommand,
            reportedTitle: reportedTitle,
            provider: agentProvider
        )
        if let localTitle = SessionTitleGenerator.automaticTitle(for: context), localTitle != generatedTitle {
            generatedTitle = localTitle
        }
        requestExternalGeneratedTitleIfNeeded(context: context)
    }

    private func updateDisplayContext(_ displayContext: SessionProjectContext) {
        // A degraded lookup can't be trusted to say "no branch / not a worktree".
        // Keep the last reading and retry later rather than clobbering it with a
        // transient false-negative. This also prevents a second consecutive failure
        // from replacing the trustworthy reading retained after the first one.
        guard !displayContext.gitLookupDegraded else {
            displayContextDegraded = true
            return
        }
        displayProject = displayContext.project
        displayBranch = displayContext.branch
        displayIsGitWorktree = displayContext.isGitWorktree
        displayIsDefaultBranch = displayContext.isDefaultBranch
        projectGroupID = displayContext.groupID
        projectGroupTitle = displayContext.groupTitle
        displayContextDegraded = displayContext.gitLookupDegraded
    }

    /// Keeps the issue binding tracking the pane's current working directory and
    /// branch, which is where a session's identity actually lives: `cd` into another
    /// issue's worktree and the link follows. A binding the cwd/branch no longer
    /// supports is stale — a pane that has moved on, or an agent that marked the
    /// session and has since exited — so detection replaces it rather than deferring
    /// to it. Only an explicit binding (`banyanctl mark --title-url`) with nothing to
    /// detect survives, since that is a deliberate choice about a directory that says
    /// nothing on its own.
    private func refreshAutoDetectedTitleURL() {
        guard let detectedReference = LinearIssueReference.detect(branch: displayBranch, cwd: cwd) else {
            if titleURLWasAutoDetected {
                titleURL = nil
                titleURLWasAutoDetected = false
            }
            return
        }

        titleURLWasAutoDetected = true
        guard titleURL != detectedReference.url else { return }
        titleURL = detectedReference.url
    }

    nonisolated private static func titleForCurrentDirectory(_ cwd: String) -> String {
        PathDisplayName.make(path: cwd)
    }

    nonisolated private static func normalizedTitleURL(_ titleURL: String?) -> String? {
        let trimmed = titleURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let rawDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDirectory.isEmpty else {
            return nil
        }
        let path: String
        if rawDirectory.hasPrefix("file://"), let url = URL(string: rawDirectory), url.isFileURL {
            path = url.path
        } else {
            path = NSString(string: rawDirectory).expandingTildeInPath
        }
        return PathDisplayName.canonicalPath(path)
    }

    private static func isConversationResetCommand(_ input: String?) -> Bool {
        let normalized = input?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "/clear" || normalized == "/new"
    }

    private static func submittedPromptTitle(from input: String?) -> String? {
        guard let rawInput = input?.trimmingCharacters(in: .whitespacesAndNewlines), !rawInput.isEmpty else {
            return nil
        }
        guard !rawInput.hasPrefix("/") else { return nil }
        guard let title = SessionTitleGenerator.titleFromPrompt(rawInput) else { return nil }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trivialResponses: Set<String> = ["c", "continue", "exit", "n", "no", "ok", "okay", "q", "quit", "y", "yes"]
        guard !trivialResponses.contains(normalized) else { return nil }
        guard title.contains(where: \.isLetter), title.count >= 4 else { return nil }
        return title
    }

    private func requestExternalGeneratedTitleIfNeeded(context: SessionTitleContext) {
        guard ExternalSessionTitleGenerator.isConfigured else { return }
        let signature = [
            context.id,
            context.command,
            context.cwd,
            context.reportedTitle ?? "",
            context.provider?.rawValue ?? ""
        ].joined(separator: "\u{1f}")
        guard signature != externalTitleSignature else { return }
        externalTitleSignature = signature
        externalTitleTask?.cancel()

        externalTitleTask = Task.detached(priority: .utility) { [weak self] in
            guard let title = ExternalSessionTitleGenerator.generateTitle(for: context) else { return }
            await MainActor.run { [weak self] in
                guard let self, !self.hasUsefulPinnedTitle, self.agentProvider != nil else { return }
                self.generatedTitle = title
                self.touch()
            }
        }
    }

    func terminate(markClosed: Bool = true) {
        terminalRefreshTask?.cancel()
        isDetachingTerminalClient = false
        loadedTerminalView?.terminate()
        isProcessStarted = false
        isRestored = false
        if markClosed {
            status = .closed
        }
        touch()
    }

    func killBackingSession() {
        terminalRefreshTask?.cancel()
        isDetachingTerminalClient = false
        status = .closed
        loadedTerminalView?.terminate()
        tmuxBackend.killSession(named: tmuxSessionName)
        isProcessStarted = false
        isRestored = false
        touch()
    }

    func detachTerminalClient() {
        guard status != .closed else { return }
        if let terminalView = loadedTerminalView, terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isProcessStarted = false
        isRestored = false
        touch()
    }

    func touch() {
        updatedAt = Date()
        onDidChange?()
    }

    private func restoredMessage() -> String {
        let commandText = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default login shell" : command
        let recoveryText = needsRecovery
            ? "The tmux session disappeared while Banyan was stopped. Use Recover to recreate it."
            : "The tmux session is not currently attached in Banyan. Use Attach to reconnect."
        return [
            "Restored Banyan session metadata.",
            "",
            "Title: \(title)",
            "Directory: \(cwd)",
            "Command: \(commandText)",
            "tmux: \(tmuxSessionName)",
            "",
            recoveryText,
            "Use Remove to kill the persisted session entry.",
            ""
        ].joined(separator: "\r\n")
    }

    private func failToStart(_ message: String) {
        isRestored = true
        isProcessStarted = false
        status = .failed
        feedOrQueue("Banyan could not attach this session.\r\n\r\n\(message)\r\n")
        onStatusSignal?(status)
        touch()
    }

    private static func terminalEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "SHELL", "TMPDIR", "SSH_AUTH_SOCK"] {
            if let value = inherited[key] {
                environment.append("\(key)=\(value)")
            }
        }
        environment.append("CLICOLOR=1")
        environment.append("CLICOLOR_FORCE=1")
        environment.append("FORCE_COLOR=3")
        return environment
    }
}

final class DetectingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?
    /// The tmux pane backing this view, so the scroll handler can hand scrollback
    /// off to tmux's copy-mode instead of keeping a duplicate local history.
    var tmuxSessionName: String?
    private var preservedScrollbackTopRow: Int?

    var hasVisibleText: Bool {
        let dimensions = terminal.getDims()
        guard dimensions.cols > 0, dimensions.rows > 0 else { return false }
        for row in 0..<dimensions.rows {
            for col in 0..<dimensions.cols {
                guard let character = terminal.getCharacter(col: col, row: row) else { continue }
                if String(character).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return true
                }
            }
        }
        return false
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let preservedTopRow = preservedScrollbackTopRow ?? (canScroll && scrollPosition < 1 ? terminal.buffer.yDisp : nil)
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: slice)
        if let preservedTopRow {
            restoreScrollbackPosition(preservedTopRow)
        }
    }

    func noteUserScrollbackPosition() {
        guard canScroll, scrollPosition < 1 else {
            preservedScrollbackTopRow = nil
            return
        }
        preservedScrollbackTopRow = terminal.buffer.yDisp
    }

    func resetForNewProcess() {
        preservedScrollbackTopRow = nil
        terminal.resetToInitialState()
        needsDisplay = true
        setNeedsDisplay(bounds)
    }

    private func restoreScrollbackPosition(_ row: Int) {
        guard canScroll else { return }
        scrollTo(row: row, notifyAccessibility: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.canScroll else { return }
            self.scrollTo(row: row, notifyAccessibility: false)
        }
    }

    private func configureInteraction() {
        // tmux owns this pane's history (see `TmuxBackend.scrollHistory`), so the
        // local buffer only has to cover what tmux repaints plus a little slack —
        // it is no longer the scrollback of record.
        //
        // The old 20_000 mirrored tmux's `history-limit`, which meant carrying a
        // second copy of the same history in a far costlier representation:
        // `BufferLine` allocates a dense `cols`-wide `CharData` array per line and
        // fills every cell, so a line costs ~6 KB whether it holds text or not, and
        // the count tracks the configured limit rather than actual content. That was
        // ~118 MB per terminal against ~35 MB for tmux's whole server.
        changeScrollback(1_000)
        allowMouseReporting = false
    }
}

private final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let sessionID: String
    var onTitle: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    var onTerminate: ((Int32?) -> Void)?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onTitle?(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onDirectoryChange?(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.onTerminate?(exitCode)
        }
    }
}
