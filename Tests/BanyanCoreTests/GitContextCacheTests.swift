import Foundation
import Testing
@testable import BanyanCore

/// Three callers poll the same directories for the same answer, at ~5 `git`
/// fork/execs each. The cache's job is to stop paying that while the checkout
/// has not moved — observable here as a remote added behind its back, which
/// rewrites `config` but not `HEAD`, and so is deliberately not seen until the
/// entry's TTL lapses.
@Test func cachedContextReusesAnAnswerWhileHEADIsUntouched() throws {
    let root = try temporaryGitDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try seededRepository(at: root.appendingPathComponent("repo"))

    let before = SessionDisplayLabel.cachedContext(
        cwd: repository.path,
        homeDirectory: "/home/test",
        environment: [:]
    )
    #expect(before.groupID == "path:\(repository.standardizedFileURL.path)")

    try runGitInRepository(["remote", "add", "origin", "git@github.com:yudu/banyan.git"], cwd: repository)

    let cached = SessionDisplayLabel.cachedContext(
        cwd: repository.path,
        homeDirectory: "/home/test",
        environment: [:]
    )
    #expect(cached.groupID == before.groupID)
    // The uncached primitive still answers from git, so callers that need the
    // truth right now have one.
    #expect(SessionDisplayLabel.context(
        cwd: repository.path,
        homeDirectory: "/home/test",
        environment: [:]
    ).groupID == "git:github.com/yudu/banyan")
}

@Test func cachedContextRefreshesWhenHEADMoves() throws {
    let root = try temporaryGitDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try seededRepository(at: root.appendingPathComponent("repo"))

    func branch() -> String? {
        SessionDisplayLabel.cachedContext(
            cwd: repository.path,
            homeDirectory: "/home/test",
            environment: [:]
        ).branch
    }

    #expect(branch() == "main")
    try runGitInRepository(["switch", "-c", "feature"], cwd: repository)
    #expect(branch() == "feature")
}

/// The gate has to watch the `HEAD` a given checkout actually writes. A linked
/// worktree keeps its own under `<main>/.git/worktrees/<name>/HEAD`, and Banyan
/// sessions usually live in worktrees — watching the main checkout's file
/// instead would freeze their branch chip.
@Test func cachedContextTracksALinkedWorktreesOwnHEAD() throws {
    let root = try temporaryGitDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try seededRepository(at: root.appendingPathComponent("repo"))
    let worktree = root.appendingPathComponent("feature")
    try runGitInRepository(["worktree", "add", "-b", "feature", worktree.path], cwd: repository)

    func branch(of directory: URL) -> String? {
        SessionDisplayLabel.cachedContext(
            cwd: directory.path,
            homeDirectory: "/home/test",
            environment: [:]
        ).branch
    }

    #expect(branch(of: worktree) == "feature")
    #expect(branch(of: repository) == "main")

    try runGitInRepository(["switch", "-c", "later"], cwd: worktree)
    #expect(branch(of: worktree) == "later")
    #expect(branch(of: repository) == "main")
}

private func temporaryGitDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BanyanGitContextCacheTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func seededRepository(at url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try runGitInRepository(["init", "--initial-branch=main"], cwd: url)
    try runGitInRepository(["config", "user.email", "test@example.com"], cwd: url)
    try runGitInRepository(["config", "user.name", "Banyan Tests"], cwd: url)
    try "test".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runGitInRepository(["add", "README.md"], cwd: url)
    try runGitInRepository(["commit", "-m", "Initial commit"], cwd: url)
    return url
}

private func runGitInRepository(_ arguments: [String], cwd: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.currentDirectoryURL = cwd
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}
