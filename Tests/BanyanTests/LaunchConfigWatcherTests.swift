@testable import Banyan
import Foundation
import Testing

private func watcherTempHome() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("banyan-launch-watcher-\(UUID().uuidString)", isDirectory: true)
}

/// Editing the watched config fires the watcher so the picker can reload
/// without a restart.
@Test @MainActor func launchConfigWatcherFiresOnContentChange() async throws {
    let home = watcherTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".banyan"), withIntermediateDirectories: true)
    let configURL = home.appendingPathComponent(".banyan/config.yml")
    try "session_launches:\n  - id: a\n    label: A\n    command: echo a\n".write(to: configURL, atomically: true, encoding: .utf8)

    let fired = ActorBox(false)
    let watcher = LaunchConfigWatcher(homeDirectory: home, watchedFiles: [configURL]) {
        Task { await fired.set(true) }
    }
    watcher.start()
    defer { watcher.stop() }

    // Give the sources a moment to arm before writing.
    try? await Task.sleep(for: .milliseconds(200))
    try "session_launches:\n  - id: b\n    label: B\n    command: echo b\n".write(to: configURL, atomically: true, encoding: .utf8)

    var didFire = false
    for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(100))
        if await fired.value {
            didFire = true
            break
        }
    }
    #expect(didFire)
}

/// Creating a previously missing agents registry fires the watcher, so a
/// `workit sync` that adds the file updates the picker live.
@Test @MainActor func launchConfigWatcherFiresOnFileCreation() async throws {
    let home = watcherTempHome()
    defer { try? FileManager.default.removeItem(at: home) }
    try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
    let agentsURL = home.appendingPathComponent(".agents/agents.yml")

    let fired = ActorBox(false)
    let watcher = LaunchConfigWatcher(homeDirectory: home, watchedFiles: [agentsURL]) {
        Task { await fired.set(true) }
    }
    watcher.start()
    defer { watcher.stop() }

    try? await Task.sleep(for: .milliseconds(200))
    try "agents:\n  a:\n    tags: [banyan]\n    command: echo a\n".write(to: agentsURL, atomically: true, encoding: .utf8)

    var didFire = false
    for _ in 0..<30 {
        try? await Task.sleep(for: .milliseconds(100))
        if await fired.value {
            didFire = true
            break
        }
    }
    #expect(didFire)
}

private actor ActorBox<T: Sendable> {
    var value: T
    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { value = newValue }
}
