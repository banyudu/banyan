import Foundation

/// A pane's grid size, as tmux reports it.
public struct PaneSize: Sendable, Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// `false` when the backend reported no geometry, in which case a resize
    /// would be invisible and cached text must not be reused.
    public var isKnown: Bool { width > 0 && height > 0 }
}

/// Memoizes the two per-session probes that dominate a supervisor tick, so a
/// quiet session costs a dictionary lookup instead of a subprocess.
///
/// A tick's work is O(live sessions), and at ~40 sessions the fan-out — one
/// `tmux capture-pane` fork/exec per live agent pane, one SQLite open per live
/// OpenCode pane — is what makes the tick expensive and the wakeups energetic.
/// Neither probe was gated on whether its answer *could* have changed, even
/// though both sources publish a cheap change signal:
///
/// - a pane's text can only differ if the pane produced output, which tmux
///   already reports as `#{window_activity}` in the batched `list-panes` the
///   tick performs anyway;
/// - OpenCode's selected model lives in a row of its database, so the file's
///   modification time bounds when the answer can have moved.
///
/// Entries survive across ticks, so the cache is owned by the app and handed to
/// each tick's `SessionStatusSynchronizer`. Callers that need an unconditionally
/// fresh read (answering a prompt, reading a pane on request) simply pass no
/// cache.
public final class SupervisorInspectionCache: @unchecked Sendable {
    /// How far a capture must trail the activity timestamp it is matched against
    /// before the pair can be reused.
    ///
    /// `#{window_activity}` has whole-second resolution, so output landing later
    /// in the *same* second as a capture would leave the timestamp unchanged and
    /// the cached text stale. Requiring a full second between them closes that
    /// window: any output at or after the capture instant then necessarily falls
    /// in a later second than the one recorded.
    private static let activityResolution: TimeInterval = 1

    /// Entries are not evicted when a session skips a tick — most sessions do,
    /// that being the point — so the map is bounded by size instead. A pane's
    /// capture is ~12KB, and tmux never reuses a pane id within a server's life,
    /// so anything beyond the live set is dead weight rather than a correctness
    /// problem.
    private static let paneCapacity = 256

    private struct PaneEntry {
        let lineLimit: Int
        let size: PaneSize
        let lastActivityAt: Date
        let capturedAt: Date
        let reading: PaneReading
        var lastUsedAt: Date
    }

    private struct OpenCodeEntry {
        let databaseModifiedAt: Date?
        let identity: OpenCodeRuntimeIdentity?
    }

    private let lock = NSLock()
    private var panes: [String: PaneEntry] = [:]
    private var openCode: [String: OpenCodeEntry] = [:]

    public init() {}

    /// A pane's capture, taken only when the pane may have changed since the last
    /// one this cache holds. A reused reading also carries the conclusions
    /// already drawn from that text, which is most of what a tick costs once the
    /// subprocess is gone.
    ///
    /// `capture` runs outside the lock: it spawns a subprocess, and holding a
    /// lock across it would serialize the whole concurrent tick.
    func read(
        paneID: String,
        lineLimit: Int,
        size: PaneSize,
        lastActivityAt: Date?,
        capture: () -> PaneReading
    ) -> PaneReading {
        if let lastActivityAt, let cached = cachedReading(
            paneID: paneID,
            lineLimit: lineLimit,
            size: size,
            lastActivityAt: lastActivityAt
        ) {
            return cached
        }

        let capturedAt = Date()
        let reading = capture()

        guard let lastActivityAt else {
            // Without an activity signal nothing can be reused later either, so
            // don't grow the map with an entry no read will ever match.
            return reading
        }
        lock.lock()
        panes[paneID] = PaneEntry(
            lineLimit: lineLimit,
            size: size,
            lastActivityAt: lastActivityAt,
            capturedAt: capturedAt,
            reading: reading,
            lastUsedAt: capturedAt
        )
        pruneLeastRecentlyUsedPanes()
        lock.unlock()
        return reading
    }

    /// OpenCode's selected model, resolved only when its database has been
    /// written since the answer was cached.
    public func openCodeIdentity(
        directory: String,
        sessionStartedAt: Date,
        databaseURL: URL?,
        resolve: () -> OpenCodeRuntimeIdentity?
    ) -> OpenCodeRuntimeIdentity? {
        guard let databaseURL, let modifiedAt = Self.modificationDate(of: databaseURL) else {
            return resolve()
        }
        let key = "\(databaseURL.path)\n\(directory)\n\(sessionStartedAt.timeIntervalSince1970)"

        lock.lock()
        let cached = openCode[key]
        lock.unlock()
        if let cached, cached.databaseModifiedAt == modifiedAt {
            return cached.identity
        }

        let identity = resolve()
        lock.lock()
        openCode[key] = OpenCodeEntry(databaseModifiedAt: modifiedAt, identity: identity)
        // Keyed by directory and session start, so bounded by the OpenCode
        // sessions that have ever run; drop the lot rather than grow forever.
        if openCode.count > Self.paneCapacity {
            openCode.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        return identity
    }

    private func cachedReading(
        paneID: String,
        lineLimit: Int,
        size: PaneSize,
        lastActivityAt: Date
    ) -> PaneReading? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = panes[paneID],
              entry.lineLimit == lineLimit,
              // The pane is still the shape it was captured at, so tmux has not
              // reflowed its text underneath us…
              entry.size == size, size.isKnown,
              // …the pane has produced nothing since the capture was matched…
              entry.lastActivityAt == lastActivityAt,
              // …and the capture trails that activity by more than tmux's
              // reporting resolution, so nothing can hide inside the same second.
              entry.capturedAt.timeIntervalSince(lastActivityAt) >= Self.activityResolution
        else {
            return nil
        }
        panes[paneID]?.lastUsedAt = Date()
        return entry.reading
    }

    /// Caller holds `lock`.
    private func pruneLeastRecentlyUsedPanes() {
        guard panes.count > Self.paneCapacity else { return }
        for paneID in panes
            .sorted(by: { $0.value.lastUsedAt < $1.value.lastUsedAt })
            .prefix(panes.count - Self.paneCapacity)
            .map(\.key) {
            panes.removeValue(forKey: paneID)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
