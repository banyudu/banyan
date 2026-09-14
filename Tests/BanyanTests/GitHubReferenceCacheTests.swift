import Foundation
import Testing
@testable import Banyan

private func makeTemporaryPersistence() -> (SessionPersistence, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("github-reference-cache-tests-\(UUID().uuidString)")
    let persistence = SessionPersistence(
        databaseURL: directory.appendingPathComponent("state.sqlite"),
        legacyJSONURL: directory.appendingPathComponent("sessions.json")
    )
    return (persistence, directory)
}

@Test func resolvedReferenceIsRememberedForGood() {
    let cache = GitHubReferenceCache()
    let url = URL(string: "https://github.com/example/repo/pull/65")!
    cache.store(.resolved(url), groupID: "git:github.com/example/repo", number: 65)

    #expect(cache.outcome(groupID: "git:github.com/example/repo", number: 65) == .resolved(url))
    // Entries are per repository and per number.
    #expect(cache.outcome(groupID: "git:github.com/example/other", number: 65) == .unknown)
    #expect(cache.outcome(groupID: "git:github.com/example/repo", number: 66) == .unknown)
}

@Test func missingReferenceExpiresAfterTheTTL() {
    let cache = GitHubReferenceCache()
    let now = Date()
    cache.store(.missing, groupID: "git:github.com/example/repo", number: 9326, now: now)

    #expect(cache.outcome(
        groupID: "git:github.com/example/repo",
        number: 9326,
        now: now.addingTimeInterval(60)
    ) == .missing)
    #expect(cache.outcome(
        groupID: "git:github.com/example/repo",
        number: 9326,
        now: now.addingTimeInterval(GitHubReferenceCache.missingTTL + 1)
    ) == .unknown)
}

@Test func cacheSurvivesARelaunch() throws {
    let (persistence, directory) = makeTemporaryPersistence()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://github.com/example/repo/pull/65")!

    let first = GitHubReferenceCache(persistence: persistence)
    first.store(.resolved(url), groupID: "git:github.com/example/repo", number: 65)
    first.store(.missing, groupID: "git:github.com/example/repo", number: 9326)

    let second = GitHubReferenceCache(persistence: persistence)
    #expect(second.outcome(groupID: "git:github.com/example/repo", number: 65) == .resolved(url))
    #expect(second.outcome(groupID: "git:github.com/example/repo", number: 9326) == .missing)
}

@Test func expiredMissesAreDroppedWhenReloading() throws {
    let (persistence, directory) = makeTemporaryPersistence()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = Date().addingTimeInterval(-GitHubReferenceCache.missingTTL - 60)

    let first = GitHubReferenceCache(persistence: persistence)
    first.store(.missing, groupID: "git:github.com/example/repo", number: 9326, now: stale)

    let second = GitHubReferenceCache(persistence: persistence)
    #expect(second.outcome(groupID: "git:github.com/example/repo", number: 9326) == .unknown)
}
