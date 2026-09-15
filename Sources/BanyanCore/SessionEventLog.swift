import Foundation

/// One status transition, as handed to a long-polling client.
public struct SessionEvent: Sendable, Equatable {
    /// Monotonic position in the log. A client passes the highest one it has seen
    /// back as `since`.
    public let cursor: Int
    public let sessionID: String
    public let status: SessionStatus
    public let previousStatus: SessionStatus?
    public let at: Date

    public init(cursor: Int, sessionID: String, status: SessionStatus, previousStatus: SessionStatus?, at: Date) {
        self.cursor = cursor
        self.sessionID = sessionID
        self.status = status
        self.previousStatus = previousStatus
        self.at = at
    }
}

public struct SessionEventBatch: Sendable, Equatable {
    public let events: [SessionEvent]
    /// The cursor to pass as `since` next time, whether or not anything was
    /// returned.
    public let cursor: Int
    /// True when the requested cursor had already aged out, so events were missed.
    /// A client that sees this re-syncs from `/list` instead of assuming continuity.
    public let truncated: Bool

    public init(events: [SessionEvent], cursor: Int, truncated: Bool) {
        self.events = events
        self.cursor = cursor
        self.truncated = truncated
    }
}

/// A bounded, cursor-addressed log of session status transitions.
///
/// Exists so an external bridge can be told *when* a session started waiting on a
/// human instead of asking on a timer. It is fed from the status-change callback
/// the app already raises, so nothing here schedules work of its own — the log is
/// a buffer, and the waiting happens in the transport.
public struct SessionEventLog: Sendable {
    /// Deep enough to cover a burst of transitions across a full sidebar while a
    /// client is between polls, shallow enough to stay a rounding error in memory.
    public static let defaultCapacity = 512

    private let capacity: Int
    private var events: [SessionEvent] = []
    private var nextCursor = 1

    public init(capacity: Int = SessionEventLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// The cursor a client that only wants future events should start from.
    public var cursor: Int { nextCursor - 1 }

    @discardableResult
    public mutating func append(
        sessionID: String,
        status: SessionStatus,
        previousStatus: SessionStatus?,
        at: Date = Date()
    ) -> SessionEvent {
        let event = SessionEvent(
            cursor: nextCursor,
            sessionID: sessionID,
            status: status,
            previousStatus: previousStatus,
            at: at
        )
        nextCursor += 1
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        return event
    }

    /// Events recorded after `since`. A nil `since` means "start from now", which
    /// is what a fresh client wants — replaying history it has no context for would
    /// make it re-announce prompts that were answered long ago.
    public func batch(since: Int?) -> SessionEventBatch {
        guard let since else {
            return SessionEventBatch(events: [], cursor: cursor, truncated: false)
        }
        let pending = events.filter { $0.cursor > since }
        let oldestRetained = events.first?.cursor ?? nextCursor
        let truncated = since + 1 < oldestRetained && since < cursor
        return SessionEventBatch(
            events: pending,
            cursor: pending.last?.cursor ?? cursor,
            truncated: truncated
        )
    }

    public mutating func removeAll() {
        events.removeAll()
    }
}
