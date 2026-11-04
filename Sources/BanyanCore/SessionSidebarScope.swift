import Foundation

/// Presentation scope for the Sessions sidebar. This never changes runtime
/// state or the workflow projection.
public enum SessionSidebarScope: String, CaseIterable, Sendable {
    case focus
    case all

    public var label: String {
        switch self {
        case .focus: "Focus"
        case .all: "All sessions"
        }
    }
}

/// Why a session belongs in the current sidebar scope.
public enum SessionFocusLane: String, Equatable, Sendable {
    /// A human decision, input, review, hold or recovery is required now.
    case act
    /// The agent or an external system is expected to continue without help.
    case watch
    /// Finished or deliberately paused work, kept visible for acknowledgement.
    case settled

    /// The lane for an unmanaged session, derived from its terminal status.
    public static func forSessionStatus(_ status: SessionStatus) -> SessionFocusLane {
        switch status {
        case .needInput, .asking, .review, .failed: .act
        case .completed, .closed: .settled
        case .running, .executing, .longRunningShell, .subagents, .idle: .watch
        }
    }

    /// Focus keeps only work that needs a human or has reached a resting point.
    public var isActionable: Bool { self != .watch }
}
