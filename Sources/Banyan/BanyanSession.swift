import AppKit
import Foundation
import SwiftTerm

@MainActor
final class BanyanSession: ObservableObject, Identifiable {
    let id: String
    let createdAt: Date
    let terminalView: LocalProcessTerminalView

    @Published var title: String
    @Published var reportedTitle: String?
    @Published var cwd: String
    @Published var command: String
    @Published var status: SessionStatus
    @Published var tone: SessionTone
    @Published var updatedAt: Date

    private var delegate: TerminalSessionDelegate?

    init(
        id: String,
        title: String,
        cwd: String,
        command: String,
        status: SessionStatus = .running,
        tone: SessionTone = .blue,
        theme: TerminalTheme
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.command = command
        self.status = status
        self.tone = tone
        self.createdAt = Date()
        self.updatedAt = Date()
        self.terminalView = LocalProcessTerminalView(frame: .zero)

        theme.apply(to: terminalView)

        let delegate = TerminalSessionDelegate(sessionID: id)
        delegate.onTitle = { [weak self] title in
            self?.reportedTitle = title
            self?.touch()
        }
        delegate.onTerminate = { [weak self] exitCode in
            guard let self else { return }
            if self.status != .closed {
                self.status = exitCode == 0 ? .completed : .failed
            }
            self.touch()
        }
        self.delegate = delegate
        self.terminalView.processDelegate = delegate
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            terminalView.startProcess(executable: shell, args: ["-l"], currentDirectory: cwd)
        } else {
            terminalView.startProcess(executable: shell, args: ["-lc", command], currentDirectory: cwd)
        }
    }

    func apply(theme: TerminalTheme) {
        theme.apply(to: terminalView)
        terminalView.needsDisplay = true
    }

    func mark(status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil) {
        if let status {
            self.status = status
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
        if markClosed {
            status = .closed
        }
        touch()
    }

    func touch() {
        updatedAt = Date()
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
