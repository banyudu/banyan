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
    let terminalView: DetectingLocalProcessTerminalView
    private var displayProject: String
    private var displayBranch: String?
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
    @Published var parentSessionID: String?
    private(set) var lastConversationResetAt: Date?

    private var delegate: TerminalSessionDelegate?
    private let tmuxBackend = TmuxBackend.shared
    var onDidChange: (() -> Void)?
    var onOutput: ((String) -> Void)?
    var onStatusSignal: ((SessionStatus) -> Void)?
    var onProcessExit: ((Int32?) -> Void)?
    private var didRenderRestoredMessage = false
    private var appliedTheme: TerminalTheme?
    private var appliedFontFamily: String?
    private var appliedFontSize: Double?
    private var externalTitleSignature: String?
    private var externalTitleTask: Task<Void, Never>?
    private var isDetachingTerminalClient = false
    private var attemptedBlankTerminalRecovery = false
    private var titleURLWasAutoDetected = false

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

    var titleLinkLabel: String? {
        LinearIssueReference.issueID(in: title)
            ?? LinearIssueReference.issueID(in: titleURL)
            ?? LinearIssueReference.detect(branch: displayBranch, cwd: cwd)?.id
    }

    var agentProvider: CodingAgentProvider? {
        CodingAgentProvider.detect(in: command) ?? detectedAgentProvider
    }

    var needsManualAttach: Bool {
        isRestored && !isProcessStarted && status == .failed
    }

    var isImportedHistory: Bool {
        historyTranscriptURL != nil
    }

    init(
        id: String,
        tmuxSessionName: String? = nil,
        title: String,
        titleURL: String? = nil,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        command: String,
        status: SessionStatus = .running,
        tone: SessionTone = .blue,
        parentSessionID: String? = nil,
        historyTranscriptURL: URL? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isRestored: Bool = false,
        theme: TerminalTheme,
        fontFamily: String? = nil,
        fontSize: Double = 13
    ) {
        let displayContext = SessionDisplayLabel.context(cwd: cwd)
        self.id = id
        self.tmuxSessionName = tmuxSessionName ?? TmuxBackend.sessionName(for: id)
        self.historyTranscriptURL = historyTranscriptURL
        self.title = title
        if let normalizedTitleURL = Self.normalizedTitleURL(titleURL) {
            self.titleURL = normalizedTitleURL
            self.titleURLWasAutoDetected = normalizedTitleURL == LinearIssueReference.detect(branch: displayContext.branch, cwd: cwd)?.url
        } else {
            let detectedReference = LinearIssueReference.detect(branch: displayContext.branch, cwd: cwd)
            self.titleURL = detectedReference?.url
            self.titleURLWasAutoDetected = detectedReference != nil
        }
        self.generatedTitle = generatedTitle
        self.detectedAgentProvider = nil
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.command = command
        self.displayProject = displayContext.project
        self.displayBranch = displayContext.branch
        self.projectGroupID = displayContext.groupID
        self.projectGroupTitle = displayContext.groupTitle
        self.status = status
        self.tone = tone
        self.parentSessionID = parentSessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isRestored = isRestored
        self.isProcessStarted = !isRestored
        self.terminalView = DetectingLocalProcessTerminalView(frame: .zero)

        apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)

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
        self.terminalView.processDelegate = delegate
        self.terminalView.onOutput = { [weak self] text in
            self?.onOutput?(text)
        }

        refreshGeneratedTitle()
    }

    func renderRestoredMessageIfNeeded(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        guard needsManualAttach, !didRenderRestoredMessage else { return }
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
        startTerminalClient()
    }

    func refreshTerminalClient() {
        guard !isImportedHistory, terminalView.process.running else { return }
        tmuxBackend.refreshClients(attachedTo: tmuxSessionName)
        terminalView.needsDisplay = true
        terminalView.setNeedsDisplay(terminalView.bounds)
    }

    func recoverBlankTerminalClientIfNeeded() {
        guard !isImportedHistory,
              !attemptedBlankTerminalRecovery,
              terminalView.process.running,
              terminalView.hasVisibleText == false else {
            return
        }
        let capturedText = tmuxBackend.captureCurrentVisibleText(paneID: tmuxSessionName)
        guard capturedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return
        }
        attemptedBlankTerminalRecovery = true
        reattachTerminalClient(resetBlankRecoveryAttempt: false)
    }

    func reattachTerminalClient(resetBlankRecoveryAttempt: Bool = true) {
        guard !isImportedHistory else { return }
        if terminalView.process.running {
            isDetachingTerminalClient = true
            terminalView.terminate()
        }
        isDetachingTerminalClient = false
        isProcessStarted = false
        isRestored = false
        terminalView.resetForNewProcess()
        startTerminalClient(resetBlankRecoveryAttempt: resetBlankRecoveryAttempt)
    }

    func restartBackingSession() {
        guard !isImportedHistory else { return }
        if terminalView.process.running {
            isDetachingTerminalClient = true
        }
        terminalView.terminate()
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
        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)
        appliedTheme = theme
        appliedFontFamily = fontFamily
        appliedFontSize = fontSize
        terminalView.needsDisplay = true
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

    func noteUserSubmittedInput(_ submittedInput: String? = nil) {
        if Self.isConversationResetCommand(submittedInput), agentProvider != nil {
            lastConversationResetAt = Date()
            if !hasUsefulPinnedTitle {
                reportedTitle = nil
                generatedTitle = nil
                externalTitleSignature = nil
            }
            touch()
        }
        guard !isImportedHistory, isProcessStarted, status != .closed, agentProvider != nil else { return }
        guard [.running, .longRunningShell, .needInput, .asking].contains(status) else { return }
        mark(status: .executing, tone: .blue)
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

    func updateCurrentDirectory(_ directory: String?) {
        guard let directory = Self.normalizedDirectory(directory), directory != cwd else { return }
        let shouldUpdateTitle = Self.titleTracksCurrentDirectory(title, isTitlePinned: isTitlePinned, cwd: cwd)
        cwd = directory
        updateDisplayContext(for: directory)
        if shouldUpdateTitle {
            title = Self.titleForCurrentDirectory(directory)
        }
        refreshAutoDetectedTitleURL()
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

    private func updateDisplayContext(for cwd: String) {
        let displayContext = SessionDisplayLabel.context(cwd: cwd)
        displayProject = displayContext.project
        displayBranch = displayContext.branch
        projectGroupID = displayContext.groupID
        projectGroupTitle = displayContext.groupTitle
    }

    private func refreshAutoDetectedTitleURL() {
        guard let detectedReference = LinearIssueReference.detect(branch: displayBranch, cwd: cwd) else {
            if titleURLWasAutoDetected {
                titleURL = nil
                titleURLWasAutoDetected = false
            }
            return
        }

        if titleURL == nil || titleURLWasAutoDetected {
            titleURL = detectedReference.url
            titleURLWasAutoDetected = true
        }
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
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isConversationResetCommand(_ input: String?) -> Bool {
        let normalized = input?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "/clear" || normalized == "/new"
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
        isDetachingTerminalClient = false
        terminalView.terminate()
        isProcessStarted = false
        isRestored = false
        if markClosed {
            status = .closed
        }
        touch()
    }

    func killBackingSession() {
        isDetachingTerminalClient = false
        terminalView.terminate()
        tmuxBackend.killSession(named: tmuxSessionName)
        isProcessStarted = false
        isRestored = false
        status = .closed
        touch()
    }

    func detachTerminalClient() {
        guard status != .closed else { return }
        if terminalView.process.running {
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
        return [
            "Restored Banyan session metadata.",
            "",
            "Title: \(title)",
            "Directory: \(cwd)",
            "Command: \(commandText)",
            "tmux: \(tmuxSessionName)",
            "",
            "The tmux session is not currently attached in Banyan.",
            "Use Attach to reconnect, or Remove to kill it.",
            ""
        ].joined(separator: "\r\n")
    }

    private func failToStart(_ message: String) {
        isRestored = true
        isProcessStarted = false
        status = .failed
        terminalView.feed(text: "Banyan could not attach this session.\r\n\r\n\(message)\r\n")
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
        changeScrollback(20_000)
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
