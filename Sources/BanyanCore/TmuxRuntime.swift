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
