import Foundation

/// The pane state needed by session supervision, independent of how tmux is
/// launched or how a frontend renders the terminal.
public struct TmuxPaneSnapshot: Sendable {
    public let paneID: String
    public let rootPID: Int
    public let currentCommand: String
    public let currentPath: String
    public let isDead: Bool
    public let isInMode: Bool

    public init(
        paneID: String,
        rootPID: Int,
        currentCommand: String,
        currentPath: String,
        isDead: Bool,
        isInMode: Bool
    ) {
        self.paneID = paneID
        self.rootPID = rootPID
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.isDead = isDead
        self.isInMode = isInMode
    }
}

/// Minimum tmux surface required by a session supervisor or a future TUI.
/// The macOS implementation can continue to use its concrete backend while
/// Linux code and tests can provide an implementation without AppKit.
public protocol TmuxSessionBackend: Sendable {
    func hasSession(named name: String) -> Bool
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot?
    func captureVisibleText(paneID: String, lineLimit: Int) -> String
}

public protocol TmuxSessionLifecycleBackend: TmuxSessionBackend {
    func ensureSession(named name: String, cwd: String, command: String) throws
    func killSession(named name: String)
}

public protocol TmuxDisplayBackend: TmuxSessionBackend {
    func captureCurrentVisibleText(paneID: String) -> String
}

public protocol TmuxAttachmentBackend: Sendable {
    var executableURL: URL { get }
    func attachArguments(for name: String) -> [String]
}

/// Complete backend surface required by the terminal frontend.
public protocol TmuxTerminalBackend: AgentSupervisorBackend, TmuxSessionLifecycleBackend, TmuxDisplayBackend, TmuxAttachmentBackend {}

/// Additional controls used by an embedded terminal client.
public protocol TmuxClientBackend: TmuxTerminalBackend {
    func configureTerminalTheme(style: String, for sessionName: String?)
    func refreshClients(attachedTo name: String)
    func scrollHistory(paneID: String, lines: Int, up: Bool)
}

/// Backend surface needed by the macOS session store for discovery and lifecycle.
public protocol TmuxSessionDiscoveryBackend: TmuxSessionLifecycleBackend {
    func listBanyanSessions() -> [String]
}

public struct SessionLaunchRequest: Sendable {
    public let sessionName: String
    public let cwd: String
    public let command: String

    public init(sessionName: String, cwd: String, command: String) {
        self.sessionName = sessionName
        self.cwd = cwd
        self.command = command
    }
}

/// Coordinates the tmux-backed part of a session lifecycle without knowing
/// anything about SwiftUI, SwiftTerm, or a particular frontend.
public struct SessionRuntimeCoordinator: Sendable {
    private let backend: any TmuxSessionLifecycleBackend

    public init(backend: any TmuxSessionLifecycleBackend = TmuxBackend.shared) {
        self.backend = backend
    }

    public func ensureBackingSession(_ request: SessionLaunchRequest) throws {
        try backend.ensureSession(
            named: request.sessionName,
            cwd: request.cwd,
            command: request.command
        )
    }

    public func removeBackingSession(named name: String) {
        backend.killSession(named: name)
    }

    public func restartBackingSession(_ request: SessionLaunchRequest) throws {
        backend.killSession(named: request.sessionName)
        try backend.ensureSession(
            named: request.sessionName,
            cwd: request.cwd,
            command: request.command
        )
    }
}
