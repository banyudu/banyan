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

/// Why managed work belongs in the current sidebar scope.
public enum SessionFocusLane: String, Equatable, Sendable {
    /// A human decision, hold or recovery is required now.
    case act
    /// The agent or an external system is expected to continue without help.
    case watch
    /// Verified, cancelled or deliberately paused work.
    case settled
}
