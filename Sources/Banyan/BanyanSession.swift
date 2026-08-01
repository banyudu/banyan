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

    var _terminalView: DetectingLocalProcessTerminalView?

    /// The SwiftTerm view backing this session, created on first access.
    ///
    /// A terminal preallocates its scrollback eagerly (~4.7 MB here), so building
    /// one per session in `init` cost ~1.7 GB across a restored workspace: every
    /// persisted row gets a `BanyanSession`, and the overwhelming majority are
    /// closed history entries that are never opened (only `SessionHistoryPresentation.sidebarBrowseLimit`
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
    var lastConversationResetAt: Date?

    var delegate: TerminalSessionDelegate?
    let tmuxBackend: any TmuxClientBackend
    let sessionRuntime: any SessionRuntimeBackend
    let telemetry: PerformanceTelemetry
    let homeDirectory: String
    let environment: [String: String]

    var launchRequest: SessionLaunchRequest {
        SessionLaunchRequest(sessionName: tmuxSessionName, cwd: cwd, command: command)
    }
    var onDidChange: (() -> Void)?
    var onOutput: ((String) -> Void)?
    var onStatusSignal: ((SessionStatus) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?
    var onProjectContextObserved: ((String, SessionProjectContext) -> Void)?
    var didRenderRestoredMessage = false
    var appliedTheme: TerminalTheme?
    var appliedFontFamily: String?
    var appliedFontSize: Double?
    /// Desired appearance, tracked even while no terminal exists so one created
    /// later comes up already styled rather than flashing an unthemed frame.
    var pendingTheme: TerminalTheme
    var pendingFontFamily: String?
    var pendingFontSize: Double
    var pendingTerminalMessage: String?
    var externalTitleSignature: String?
    var externalTitleTask: Task<Void, Never>?
    var isDetachingTerminalClient = false
    var attemptedBlankTerminalRecovery = false
    var titleURLWasAutoDetected = false
    var terminalRefreshTask: Task<Void, Never>?

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
        fontSize: Double = 13,
        tmuxBackend: any TmuxClientBackend,
        telemetry: PerformanceTelemetry,
        host: HostRuntimeContext
    ) {
        self.tmuxBackend = tmuxBackend
        self.sessionRuntime = SessionRuntimeCoordinator(backend: tmuxBackend)
        self.telemetry = telemetry
        self.homeDirectory = host.homeDirectory.path
        self.environment = host.environment
        let resolvedDisplayContext = displayContext ?? SessionDisplayLabel.context(
            cwd: cwd,
            homeDirectory: self.homeDirectory,
            environment: self.environment
        )
        self.id = id
        self.tmuxSessionName = tmuxSessionName ?? SessionIdentityPolicy.sessionName(for: id)
        self.historyTranscriptURL = historyTranscriptURL
        self.title = title
        let detectedReference = LinearIssueReference.detect(
            branch: resolvedDisplayContext.branch,
            cwd: cwd,
            environment: environment
        )
        if let normalizedTitleURL = SessionInputPolicy.normalizedTitleURL(titleURL) {
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
        // Recover the launched identity synchronously from the persisted command.
        // A restored/recovered session starts in `.running` before the supervisor
        // has had a chance to inspect its process tree; leaving this nil makes the
        // sidebar render every agent as a plain terminal during that window.
        self.detectedAgentProvider = CodingAgentProvider.detect(in: command)
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
            if let nextStatus = SessionLifecyclePolicy.statusAfterTerminalExit(
                currentStatus: self.status,
                hasBackingSession: self.tmuxBackend.hasSession(named: self.tmuxSessionName),
                exitCode: exitCode
            ) {
                self.status = nextStatus
                if nextStatus != .running {
                    self.onStatusSignal?(self.status)
                }
            }
            self.touch()
        }
        self.delegate = delegate

        refreshGeneratedTitle()
    }

    func makeTerminalView() -> DetectingLocalProcessTerminalView {
        let view = DetectingLocalProcessTerminalView(frame: .zero)
        view.tmuxSessionName = tmuxSessionName
        // SwiftTerm's implicit link reporting recognizes raw http(s) URLs and
        // its modifier-aware mode previews/opens them on Cmd-click. Keep plain
        // clicks available for normal terminal selection and input.
        view.linkHighlightMode = .hoverWithModifier
        pendingTheme.apply(to: view, fontFamily: pendingFontFamily, fontSize: pendingFontSize)
        appliedTheme = pendingTheme
        appliedFontFamily = pendingFontFamily
        appliedFontSize = pendingFontSize
        view.processDelegate = delegate
        view.onOutput = { [weak self] text in
            self?.onOutput?(text)
        }
        delegate?.onOpenLink = { [weak self] link in
            self?.openTerminalLink(link)
        }
        if let pendingTerminalMessage {
            view.feed(text: pendingTerminalMessage)
            self.pendingTerminalMessage = nil
        }
        return view
    }

    func openTerminalLink(_ link: String) {
        if let number = TerminalFooterLinkifier.pullRequestNumber(in: link) {
            let environment = self.environment
            let homeDirectory = self.homeDirectory
            Task.detached(priority: .utility) { [cwd, environment, homeDirectory] in
                guard let url = try? await GitHubPullRequestClient.pullRequestURL(
                    number: number,
                    cwd: cwd,
                    environment: environment,
                    homeDirectory: homeDirectory
                ) else {
                    return
                }
                await MainActor.run {
                    _ = NSWorkspace.shared.open(url)
                }
            }
            return
        }

        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    /// Writes to the terminal if one exists, otherwise holds the text until one is
    /// created. A background start can fail before any terminal is allocated, and
    /// that diagnostic still needs to be there when the session is later opened.
    func feedOrQueue(_ text: String) {
        if let terminalView = loadedTerminalView {
            terminalView.feed(text: text)
        } else {
            pendingTerminalMessage = (pendingTerminalMessage ?? "") + text
        }
    }

}
