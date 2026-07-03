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

    @Published var title: String
    @Published var reportedTitle: String?
    @Published var cwd: String
    @Published var command: String
    @Published var status: SessionStatus
    @Published var tone: SessionTone
    @Published var updatedAt: Date
    @Published var isRestored: Bool
    @Published var isProcessStarted: Bool

    private var delegate: TerminalSessionDelegate?
    private let tmuxBackend = TmuxBackend.shared
    var onDidChange: (() -> Void)?
    var onOutput: ((String) -> Void)?
    var onStatusSignal: ((SessionStatus) -> Void)?
    private var didRenderRestoredMessage = false

    var displayTitle: String {
        SessionDisplayLabel.make(
            project: displayProject,
            branch: displayBranch,
            title: title,
            id: id,
            command: command
        )
    }

    init(
        id: String,
        tmuxSessionName: String? = nil,
        title: String,
        cwd: String,
        command: String,
        status: SessionStatus = .running,
        tone: SessionTone = .blue,
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
        self.cwd = cwd
        self.command = command
        self.displayProject = displayContext.project
        self.displayBranch = displayContext.branch
        self.status = status
        self.tone = tone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isRestored = isRestored
        self.isProcessStarted = !isRestored
        self.terminalView = DetectingLocalProcessTerminalView(frame: .zero)

        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)

        let delegate = TerminalSessionDelegate(sessionID: id)
        delegate.onTitle = { [weak self] title in
            self?.reportedTitle = title
            self?.touch()
        }
        delegate.onTerminate = { [weak self] exitCode in
            guard let self else { return }
            self.isProcessStarted = false
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
            currentDirectory: cwd
        )
        touch()
    }

    func apply(theme: TerminalTheme, fontFamily: String? = nil, fontSize: Double = 13) {
        theme.apply(to: terminalView, fontFamily: fontFamily, fontSize: fontSize)
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
        }
        touch()
    }

    func terminate(markClosed: Bool = true) {
        terminalView.terminate()
        isProcessStarted = false
        isRestored = false
        if markClosed {
            status = .closed
        }
        touch()
    }

    func killBackingSession() {
        terminalView.terminate()
        tmuxBackend.killSession(named: tmuxSessionName)
        isProcessStarted = false
        isRestored = false
        status = .closed
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
}

final class DetectingLocalProcessTerminalView: LocalProcessTerminalView {
    var onOutput: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        changeScrollback(20_000)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        changeScrollback(20_000)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let text = String(bytes: slice, encoding: .utf8) {
            onOutput?(text)
        }
        super.dataReceived(slice: slice)
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
