import Foundation

/// Remembers `#123` reference lookups so repeated clicks do not re-ask GitHub.
///
/// A resolved reference is permanent: pull request and issue numbers are never
/// reused, so once `gh` has answered with a URL there is nothing left to check.
/// A miss is only believed for `missingTTL`, because the number can be created
/// moments after the first click. Only answers that came from `gh` are stored —
/// the repository fallback is a guess, so it must not pin a URL forever.
final class GitHubReferenceCache: @unchecked Sendable {
    static let missingTTL: TimeInterval = 10 * 60

    enum Outcome: Equatable {
        case resolved(URL)
        case missing
        case unknown
    }

    private let lock = NSLock()
    private let persistence: (any SessionStorePersistenceBackend)?
    private var entriesByKey: [String: GitHubReferenceCacheSnapshot.Entry] = [:]
    private var didLoadFromPersistence = false

    init(persistence: (any SessionStorePersistenceBackend)? = nil) {
        self.persistence = persistence
    }

    func outcome(groupID: String, number: Int, now: Date = Date()) -> Outcome {
        lock.lock()
        loadFromPersistenceIfNeededLocked()
        let entry = entriesByKey[Self.key(groupID: groupID, number: number)]
        lock.unlock()

        guard let entry else { return .unknown }
        if let rawURL = entry.url {
            return URL(string: rawURL).map(Outcome.resolved) ?? .unknown
        }
        guard now.timeIntervalSince(entry.checkedAt) < Self.missingTTL else { return .unknown }
        return .missing
    }

    /// Records a verified answer. Callers must only store outcomes that came
    /// from a `gh` lookup which actually ran.
    func store(_ outcome: Outcome, groupID: String, number: Int, now: Date = Date()) {
        let entry: GitHubReferenceCacheSnapshot.Entry
        switch outcome {
        case .resolved(let url):
            entry = .init(groupID: groupID, number: number, url: url.absoluteString, checkedAt: now)
        case .missing:
            entry = .init(groupID: groupID, number: number, url: nil, checkedAt: now)
        case .unknown:
            return
        }

        lock.lock()
        loadFromPersistenceIfNeededLocked()
        entriesByKey[Self.key(groupID: groupID, number: number)] = entry
        let snapshot = GitHubReferenceCacheSnapshot(entries: Array(entriesByKey.values))
        lock.unlock()

        persistence?.saveGitHubReferenceCache(snapshot)
    }

    private func loadFromPersistenceIfNeededLocked() {
        guard !didLoadFromPersistence else { return }
        didLoadFromPersistence = true
        guard let snapshot = persistence?.loadGitHubReferenceCache() else { return }
        // Expired misses would only force a fresh lookup to be remembered again.
        let cutoff = Date().addingTimeInterval(-Self.missingTTL)
        for entry in snapshot.entries where entry.url != nil || entry.checkedAt > cutoff {
            entriesByKey[Self.key(groupID: entry.groupID, number: entry.number)] = entry
        }
    }

    private static func key(groupID: String, number: Int) -> String {
        "\(groupID)#\(number)"
    }
}
