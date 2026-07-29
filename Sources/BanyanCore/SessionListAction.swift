import Foundation

/// Frontend-neutral commands supported by a session list.
public enum SessionListAction: Sendable, Equatable {
    case quit
    case toggleHistory
    case searchHistory
    case next
    case previous
    case pageNext
    case pagePrevious
    case refresh
    case recover
    case newSession
    case newCustomSession
    case rename
    case close
    case remove
    case activate
    case trimResume
    case unknown
}
