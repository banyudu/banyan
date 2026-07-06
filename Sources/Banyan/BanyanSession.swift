import AppKit
import BanyanCore
import Foundation
import SwiftTerm

@MainActor
final class BanyanSession: ObservableObject, Identifiable {
    let id: String
    let tmuxSessionName: String
    let createdAt: Date
    let terminalView: DetectingLocalProcessTerminalView
    private let displayProject: String
    private let displayBranch: String?
    let projectGroupID: String
    let projectGroupTitle: String

    @Published var title: String
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

    var agentProvider: CodingAgentProvider? {
        CodingAgentProvider.detect(in: command) ?? detectedAgentProvider
    }

    init(
        id: String,
        tmuxSessionName: String? = nil,
        title: String,
        generatedTitle: String? = nil,
        isTitlePinned: Bool = false,
        cwd: String,
        command: String,
        status: SessionStatus = .running,
        tone: SessionTone = .blue,
        parentSessionID: String? = nil,
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
        self.title = title
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
        guard isRestored, !didRenderRestoredMessage else { return }
        guard terminalView.bounds.width > 80, terminalView.bounds.height > 80 else { return }
        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)
        terminalView.resizeSubviews(withOldSize: .zero)
        terminalView.feed(text: restoredMessage())
        didRenderRestoredMessage = true
    }

    func start() {
        guard !terminalView.process.running else { return }
        isDetachingTerminalClient = false
        do {
            try tmuxBackend.ensureSession(named: tmuxSessionName, cwd: cwd, command: command)
        } catch {
            failToStart(error.localizedDescription)
            return
        }
        isRestored = false
        isProcessStarted = true
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

    func mark(status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil) {
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
        refreshGeneratedTitle()
        touch()
    }

    func markDetectedAgentProvider(_ provider: CodingAgentProvider?) {
        guard detectedAgentProvider != provider else { return }
        detectedAgentProvider = provider
        refreshGeneratedTitle()
        touch()
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
        let context = SessionTitleContext(
            id: id,
            baseTitle: title,
            isTitlePinned: hasUsefulPinnedTitle,
            cwd: cwd,
            project: displayProject,
            branch: displayBranch,
            command: command,
            reportedTitle: reportedTitle,
            provider: agentProvider
        )
        if let localTitle = SessionTitleGenerator.automaticTitle(for: context), localTitle != generatedTitle {
            generatedTitle = localTitle
        }
        requestExternalGeneratedTitleIfNeeded(context: context)
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
        isRestored = true
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        let shouldPreserveScroll = canScroll && scrollPosition < 0.999
        let preservedScrollPosition = scrollPosition
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: slice)
        if shouldPreserveScroll {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canScroll else { return }
                self.scroll(toPosition: preservedScrollPosition)
            }
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

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.onTerminate?(exitCode)
        }
    }
}
