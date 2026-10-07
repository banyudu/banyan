import AppKit
import BanyanCore
import Foundation
import SwiftTerm

/// A session whose agent runs as a command in a dedicated tmux session,
/// rendered by a SwiftTerm client. Closing it kills that tmux session.
@MainActor
final class TerminalSession: BanyanSession {
    let tmuxSessionName: String
    var nativeCodexProvenance: CodexThreadBinding?
    override var codexBinding: CodexThreadBinding? {
        guard var binding = nativeCodexProvenance else { return nil }
        if binding.threadID == nil, let agentSessionID {
            binding.threadID = agentSessionID
            binding.creationAttempted = true
        }
        return binding
    }

    var _terminalView: DetectingLocalProcessTerminalView?

    /// The SwiftTerm view backing this session, created on first access.
    ///
    /// A terminal preallocates its scrollback eagerly (~4.7 MB here), so building
    /// one per session in `init` cost ~1.7 GB across a restored workspace: every
    /// persisted row gets a session object, and the overwhelming majority are
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

    /// Non-allocating peek. `nil` before first display and after cache eviction,
    /// so repaint and teardown paths never create a terminal just to discard it.
    var loadedTerminalView: DetectingLocalProcessTerminalView? {
        _terminalView
    }

    var delegate: TerminalSessionDelegate?
    let tmuxBackend: any TmuxClientBackend
    let sessionRuntime: any SessionRuntimeBackend

    var launchRequest: SessionLaunchRequest {
        SessionLaunchRequest(sessionName: tmuxSessionName, cwd: cwd, command: command, banyanSessionID: id)
    }

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
    var isDetachingTerminalClient = false
    var isInactiveTerminalClientDetached = false
    var attemptedBlankTerminalRecovery = false
    var terminalRefreshTask: Task<Void, Never>?
    /// Invalidates asynchronous work that was launched for a previous client.
    var terminalClientGeneration = UUID()

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
        isSuspended: Bool = false,
        displayContext: SessionProjectContext? = nil,
        theme: TerminalTheme,
        fontFamily: String? = nil,
        fontSize: Double = 13,
        tmuxBackend: any TmuxClientBackend,
        telemetry: PerformanceTelemetry,
        host: HostRuntimeContext,
        githubReferenceCache: GitHubReferenceCache? = nil
    ) {
        self.tmuxSessionName = tmuxSessionName ?? SessionIdentityPolicy.sessionName(for: id)
        self.tmuxBackend = tmuxBackend
        self.sessionRuntime = SessionRuntimeCoordinator(backend: tmuxBackend)
        self.pendingTheme = theme
        self.pendingFontFamily = fontFamily
        self.pendingFontSize = fontSize
        super.init(
            id: id,
            title: title,
            titleURL: titleURL,
            titleURLWasAutoDetected: titleURLWasAutoDetected,
            generatedTitle: generatedTitle,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            command: command,
            status: status,
            tone: tone,
            parentSessionID: parentSessionID,
            agentSessionID: agentSessionID,
            historyTranscriptURL: historyTranscriptURL,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isRestored: isRestored,
            needsRecovery: needsRecovery,
            isSuspended: isSuspended,
            displayContext: displayContext,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )

        let delegate = TerminalSessionDelegate(sessionID: id)
        delegate.isCurrentSource = { [weak self] source in
            self?.loadedTerminalView === source
        }
        delegate.onTitle = { [weak self] title in
            guard let self else { return }
            // Agents emit generic terminal labels such as "Claude session" or
            // "Codex session-83". Those are runtime chrome, not conversation
            // titles; accepting them here overwrites a useful prompt title and
            // makes the sidebar appear to reset. Keep terminal-title adoption
            // for useful agent-provided names only.
            guard let usefulTitle = SessionDisplayPolicy.usefulAgentTitle(title) else { return }
            guard self.reportedTitle != usefulTitle else { return }
            self.reportedTitle = usefulTitle
            self.refreshGeneratedTitle()
            self.touch()
        }
        delegate.onDirectoryChange = { [weak self] directory in
            self?.updateCurrentDirectoryAsync(directory)
        }
        delegate.onTerminate = { [weak self] exitCode in
            guard let self else { return }
            if self.isDetachingTerminalClient {
                self.isDetachingTerminalClient = false
                if !self.isInactiveTerminalClientDetached {
                    self.isProcessStarted = false
                }
                self.touch()
                return
            }
            self.isProcessStarted = false
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

    // MARK: - Backend interface

    override var backendKind: SessionBackendKind { .terminal }

    override var persistedTmuxSessionName: String? { tmuxSessionName }

    override var canRestart: Bool { true }

    override var backingSessionName: String { "tmux session" }

    override var closeConsequence: String {
        "Closing \(displayTitle) will kill its tmux session."
    }

    override var matchesAgentTranscripts: Bool { true }

    override func siblingLaunch(profiles: [NewSessionLaunch], codexLaunchMode: CodexLaunchMode) -> SessionLaunchSpec {
        .terminal(command: NewSessionLaunch.siblingCommand(
            sessionCommand: command,
            provider: agentProvider,
            profiles: profiles,
            codexLaunchMode: codexLaunchMode
        ))
    }

    override func matchesLaunchProfile(_ profile: NewSessionLaunch) -> Bool {
        profile.puck == nil && profile.command == command
    }

    /// Start the tmux backing (and its launch command) without attaching a visible
    /// terminal client, so a session spawned in the background actually runs without
    /// stealing selection/focus. When the session is later selected, `start()` attaches
    /// the visible client to this already-running tmux session (`ensureSession` is idempotent).
    override func startBackgroundBackendIfNeeded() {
        guard !isImportedHistory, status != .closed, !isSuspended else { return }
        // Deliberately does not attach a visible client, so it must not create a
        // terminal either — an absent one is by definition not running.
        guard !isProcessStarted, loadedTerminalView?.process.running != true else { return }
        // Optimistically mark running so the sidebar updates immediately; the actual
        // tmux work (subprocess spawns) runs off the main thread to avoid freezing the
        // UI while a session is created via banyanctl.
        isRestored = false
        status = .running
        touch()
        startBackingSessionInBackground()
    }

    override func closeBackingSession() {
        killBackingSession()
    }

    override func terminate(markClosed: Bool = true) {
        stopTerminalClient()
        super.terminate(markClosed: markClosed)
    }

    /// Parks the session: Banyan stops observing and rendering it, while its tmux
    /// session and agent process keep running untouched.
    override func suspend() {
        guard !isImportedHistory, status != .closed, !isSuspended else { return }
        isSuspended = true
        // Drops the SwiftTerm client only. Reattaching later rebuilds the buffer
        // from the live pane, so no scrollback is lost.
        detachTerminalClient()
    }

    /// Nothing observed this session while it was parked, so a tmux server that
    /// exited meanwhile is only discovered here. One `has-session` probe settles
    /// whether the row re-enters supervision or needs recovery.
    override func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if tmuxBackend.hasSession(named: tmuxSessionName) {
            // The backing session ran the whole time, so rejoin the supervisor
            // tick immediately rather than waiting for a visible client to attach.
            isProcessStarted = true
            // This probe outranks anything the liveness sweep concluded earlier.
            needsRecovery = false
        } else {
            // Same shape as a session restored without its tmux server: persisted
            // metadata, nothing behind it. `needsManualAttach` reads all three
            // fields, so the recovery banner needs `isRestored` set here too.
            isProcessStarted = false
            isRestored = true
            needsRecovery = true
        }
        touch()
    }

    override func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13, force: Bool = false) {
        guard force || appliedTheme != theme || appliedFontFamily != fontFamily || appliedFontSize != fontSize else {
            return
        }
        pendingTheme = theme
        pendingFontFamily = fontFamily
        pendingFontSize = fontSize
        // A theme change for a session with no terminal yet is just bookkeeping;
        // `makeTerminalView` applies it if and when one is created.
        guard let view = loadedTerminalView else { return }
        theme.apply(to: view, fontFamily: fontFamily, fontSize: fontSize)
        tmuxBackend.configureTerminalTheme(style: theme.tmuxDefaultStyle, for: tmuxSessionName)
        appliedTheme = theme
        appliedFontFamily = fontFamily
        appliedFontSize = fontSize
        view.requestFullRedraw()
    }

    /// Switching renderers on a live session rebuilds its drawing surface, so
    /// it only touches sessions that already have a terminal; the rest resolve
    /// the preference in `makeTerminalView`.
    override func apply(renderer: TerminalRendererPreference) {
        loadedTerminalView?.rendererPreference = renderer
    }

    /// Writes to the terminal if one exists, otherwise holds the text until one is
    /// created. A background start can fail before any terminal is allocated, and
    /// that diagnostic still needs to be there when the session is later opened.
    override func feedOrQueue(_ text: String) {
        if let terminalView = loadedTerminalView {
            terminalView.feed(text: text)
        } else {
            pendingTerminalMessage = (pendingTerminalMessage ?? "") + text
        }
    }

    // MARK: - Terminal view

    func makeTerminalView() -> DetectingLocalProcessTerminalView {
        let view = DetectingLocalProcessTerminalView(frame: .zero)
        view.telemetry = telemetry
        view.telemetrySessionID = id
        view.rendererPreference = TerminalRendererPreference.resolvedDefault
        view.tmuxSessionName = tmuxSessionName
        // SwiftTerm's implicit link reporting recognizes raw http(s) URLs and
        // its modifier-aware mode previews/opens them on Cmd-click. Keep plain
        // clicks available for normal terminal selection and input.
        view.linkHighlightMode = .hoverWithModifier
        // Keep implicit links available on Cmd-hover and Cmd-click, but do not
        // scan every changed terminal row during painting just to color links.
        // Full-screen agents rewrite most rows per frame, and the implicit-link
        // ICU regex dominated live draw samples even with per-row caching.
        view.highlightDetectedLinks = false
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
        if let number = Self.referenceNumber(in: link) {
            openGitHubReference(number: number)
            return
        }

        guard let url = Self.terminalLinkURL(link) else {
            return
        }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    /// A bare `#123` printed by an agent: resolve it as a pull request first,
    /// then an issue, then through the session repository. Nothing opens when
    /// the repository is known not to contain the number — a guessed URL would
    /// only 404.
    private func openGitHubReference(number: Int) {
        let cwd = self.cwd
        let environment = self.environment
        let homeDirectory = self.homeDirectory
        let repositoryGroupID = self.projectGroupID
        let cache = self.githubReferenceCache
        Task.detached(priority: .utility) {
            let url = await GitHubReferenceResolver.resolve(
                number: number,
                cwd: cwd,
                environment: environment,
                homeDirectory: homeDirectory,
                repositoryGroupID: repositoryGroupID,
                cache: cache
            )
            await MainActor.run {
                if let url {
                    _ = NSWorkspace.shared.open(url)
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    /// The `#123` form agents print in status lines and footers. Explicit OSC 8
    /// hyperlinks still arrive as full URLs and are opened through
    /// `terminalLinkURL`.
    nonisolated static func referenceNumber(in link: String) -> Int? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    static func terminalLinkURL(_ link: String) -> URL? {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }

        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        if ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        return url.isFileURL ? url : nil
    }
}
