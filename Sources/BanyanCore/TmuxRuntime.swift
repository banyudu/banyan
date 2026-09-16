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
    /// When this pane's window last produced output, as tmux reports it
    /// (`#{window_activity}`, whole-second resolution). Reading the pane does not
    /// bump it — only output does — which makes it a sound "nothing can have
    /// changed" signal for skipping a capture.
    ///
    /// `nil` when the backend cannot supply it. Callers must then assume the pane
    /// may have changed and capture it.
    public let lastActivityAt: Date?
    /// The pane's grid size. A resize reflows the pane's text without the process
    /// writing anything, so text captured at one size must not be reused at
    /// another. `0` means the backend did not report it.
    public let width: Int
    public let height: Int

    public init(
        paneID: String,
        rootPID: Int,
        currentCommand: String,
        currentPath: String,
        isDead: Bool,
        isInMode: Bool,
        lastActivityAt: Date? = nil,
        width: Int = 0,
        height: Int = 0
    ) {
        self.paneID = paneID
        self.rootPID = rootPID
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.isDead = isDead
        self.isInMode = isInMode
        self.lastActivityAt = lastActivityAt
        self.width = width
        self.height = height
    }
}

/// Minimum tmux surface required by a session supervisor or a future TUI.
/// The macOS implementation can continue to use its concrete backend while
/// Linux code and tests can provide an implementation without AppKit.
public protocol TmuxSessionLookupBackend: Sendable {
    func hasSession(named name: String) -> Bool
}

public protocol TmuxSessionBackend: TmuxSessionLookupBackend {
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot?
    /// Returns the primary pane for each requested session in one backend call
    /// when the implementation can batch the lookup. The default keeps small
    /// test and alternate backends source-compatible.
    func primaryPaneSnapshots(named names: Set<String>) -> [String: TmuxPaneSnapshot]
    func captureVisibleText(paneID: String, lineLimit: Int) -> String
}

public extension TmuxSessionBackend {
    func primaryPaneSnapshots(named names: Set<String>) -> [String: TmuxPaneSnapshot] {
        names.reduce(into: [:]) { snapshots, name in
            if let snapshot = primaryPaneSnapshot(named: name) {
                snapshots[name] = snapshot
            }
        }
    }
}

public protocol TmuxSessionLifecycleBackend: TmuxSessionLookupBackend {
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws
    func killSession(named name: String)
}

public extension TmuxSessionLifecycleBackend {
    /// Convenience for callers (mostly tests) that do not model a Banyan identity.
    func ensureSession(named name: String, cwd: String, command: String) throws {
        try ensureSession(named: name, cwd: cwd, command: command, banyanSessionID: nil)
    }
}

/// Writes into a pane from outside it.
///
/// Kept separate from the read-only surfaces because this is the one place the
/// control API can type into a process running with the user's privileges.
/// Injection goes through tmux rather than the embedded terminal's PTY: a
/// background session deliberately has no attached client, and the in-process
/// write path only reaches panes that do.
public protocol TmuxInputBackend: Sendable {
    /// Presses named keys in the pane.
    func sendKeys(paneID: String, keys: [TmuxKey]) throws
    /// Types text verbatim, never interpreted as key names.
    func sendLiteral(paneID: String, text: String) throws
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
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?)
}

/// Backend surface needed by the macOS session store for discovery, supervision,
/// and answering a session that is blocked on a human.
public protocol TmuxSessionStoreBackend: AgentSupervisorBackend, TmuxSessionLifecycleBackend, TmuxInputBackend {
    func listBanyanSessions() -> [String]
}

public struct SessionLaunchRequest: Sendable {
    public let sessionName: String
    public let cwd: String
    public let command: String
    /// Banyan session id owning this tmux session. Carried so the backend can
    /// expose it inside the pane (`BANYAN_SESSION_ID`); nil for callers that
    /// do not model a Banyan identity (mostly tests).
    public let banyanSessionID: String?

    public init(sessionName: String, cwd: String, command: String, banyanSessionID: String? = nil) {
        self.sessionName = sessionName
        self.cwd = cwd
        self.command = command
        self.banyanSessionID = banyanSessionID
    }
}

/// Coordinates the tmux-backed part of a session lifecycle without knowing
/// anything about SwiftUI, SwiftTerm, or a particular frontend.
public protocol SessionRuntimeBackend: Sendable {
    func ensureBackingSession(_ request: SessionLaunchRequest) throws
    func removeBackingSession(named name: String)
    func restartBackingSession(_ request: SessionLaunchRequest) throws
}

public struct SessionRuntimeCoordinator: Sendable, SessionRuntimeBackend {
    private let backend: any TmuxSessionLifecycleBackend

    public init(backend: any TmuxSessionLifecycleBackend) {
        self.backend = backend
    }

    public func ensureBackingSession(_ request: SessionLaunchRequest) throws {
        try backend.ensureSession(
            named: request.sessionName,
            cwd: request.cwd,
            command: request.command,
            banyanSessionID: request.banyanSessionID
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
            command: request.command,
            banyanSessionID: request.banyanSessionID
        )
    }
}
