import Foundation

/// Bounded legacy event fallback for daemons without paged history support.
public struct PuckRecentHistory: Sendable {
    public let events: [PuckSessionEvent]
    public let cursor: UInt64
    public let truncated: Bool
    public let incomplete: Bool
    public init(events: [PuckSessionEvent], cursor: UInt64, truncated: Bool, incomplete: Bool) {
        self.events = events; self.cursor = cursor; self.truncated = truncated; self.incomplete = incomplete
    }
}

public protocol PuckRecentHistoryReading: Sendable {
    func recentEvents(_ id: String, maximum: Int) throws -> PuckRecentHistory
}

extension PuckDaemonClient: PuckRecentHistoryReading {
    public func recentEvents(_ id: String, maximum: Int) throws -> PuckRecentHistory {
        let limit = min(max(maximum, 1), 200)
        let first = try events(id, after: 0)
        let target = first.cursor
        let start = target > UInt64(limit) ? target - UInt64(limit) : 0
        var page = start == 0 ? first : try events(id, after: start)
        var cursor = start
        var collected: [PuckSessionEvent] = []
        var pages = 0
        while pages < 4 {
            pages += 1
            let fresh = page.events.filter { $0.cursor > cursor && $0.cursor <= target }
            if let last = fresh.last { collected.append(contentsOf: fresh); cursor = last.cursor }
            if cursor >= target || fresh.isEmpty || collected.count >= limit { break }
            page = try events(id, after: cursor)
        }
        return PuckRecentHistory(events: Array(collected.prefix(limit)), cursor: target, truncated: start > 0,
                                 incomplete: cursor < target || collected.count > limit)
    }
}
