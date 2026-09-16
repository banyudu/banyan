import Foundation

/// Memoizes `SessionDisplayLabel.context` per directory, shared by everything
/// that asks for a session's repository context.
///
/// Resolving one directory costs ~5 `git` fork/execs (~30ms). Three callers want
/// the same answer for the same directories — the branch-refresh timer, pane
/// directory changes, and the selected-session context resolver — and the timer
/// alone re-resolved up to 20 directories every 15 seconds, so a large workspace
/// spent hundreds of process spawns a minute re-deriving a label that had not
/// moved.
///
/// The answer only changes when someone checks out, detaches HEAD, or edits the
/// repository's remotes. A checkout rewrites this checkout's `HEAD` file, so its
/// modification time is a sound change signal that costs one `stat`. Remote
/// edits are rarer and leave `HEAD` alone, so a TTL bounds how long any answer
/// may be reused regardless.
///
/// Results whose git lookups *degraded* (timed out, failed to launch) are never
/// cached: they are unreliable false-negatives, and pinning one would keep a
/// worktree grouped by path for as long as the entry lived.
final class GitContextCache: @unchecked Sendable {
    /// Longest a repository's context may be reused while its `HEAD` is
    /// untouched. Covers the changes `HEAD` cannot see, such as adding a remote.
    private static let repositoryTTL: TimeInterval = 5 * 60

    /// Directories that are not repositories, or whose git layout `HEAD` could
    /// not be located in, have no change signal to watch. They keep the poll
    /// cadence they had before this cache existed, so `git init` in a session's
    /// directory still shows up as promptly as it used to. They also cost a
    /// single failed `git rev-parse`, so there is little to save.
    private static let unwatchableTTL: TimeInterval = 15

    static let shared = GitContextCache()

    private struct Entry {
        let context: SessionProjectContext
        let headPath: String?
        let headModifiedAt: Date?
        let resolvedAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func context(
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> SessionProjectContext {
        let key = "\(homeDirectory)\n\(cwd)"
        let now = Date()

        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached, isFresh(cached, at: now) {
            return cached.context
        }

        let resolved = SessionDisplayLabel.resolvedContext(
            cwd: cwd,
            homeDirectory: homeDirectory,
            environment: environment
        )
        guard !resolved.context.gitLookupDegraded else {
            return resolved.context
        }

        lock.lock()
        entries[key] = Entry(
            context: resolved.context,
            headPath: resolved.headPath,
            headModifiedAt: resolved.headPath.flatMap(Self.modificationDate),
            resolvedAt: now
        )
        // Bounded by the directories the open sessions live in, but a long-lived
        // app sees closed ones too; cap defensively rather than grow forever.
        if entries.count > 256 {
            entries.removeAll(keepingCapacity: true)
        }
        lock.unlock()
        return resolved.context
    }

    private func isFresh(_ entry: Entry, at now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.resolvedAt)
        guard let headPath = entry.headPath else {
            return age < Self.unwatchableTTL
        }
        guard age < Self.repositoryTTL else { return false }
        return Self.modificationDate(headPath) == entry.headModifiedAt
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

public extension SessionDisplayLabel {
    /// Repository context for a directory, reusing a recent answer while the
    /// checkout's `HEAD` is untouched. Callers that poll — the branch-refresh
    /// timer, directory-change updates, the selected-session resolver — should
    /// use this; `context(cwd:…)` stays the uncached primitive.
    static func cachedContext(
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> SessionProjectContext {
        GitContextCache.shared.context(
            cwd: cwd,
            homeDirectory: homeDirectory,
            environment: environment
        )
    }
}
