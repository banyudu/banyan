import Foundation

/// Frontend-neutral commands supported by a session list.
public enum SessionListAction: Sendable {
    case quit
    case toggleHistory
    case next
    case previous
    case refresh
    case recover
    case newSession
    case close
    case remove
    case activate
    case trimResume
    case unknown
}
