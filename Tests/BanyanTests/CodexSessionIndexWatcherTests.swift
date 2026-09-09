import Foundation
import BanyanCore
import Testing
@testable import Banyan

/// Waits for `condition` without blocking the main actor, so the watcher's
/// handlers and its debounce task can run while the test is waiting.
@MainActor
private func waitFor(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class ChangeCounter {
    var count = 0
}

@MainActor
@Test func codexIndexWatcherReportsAnAppendedThreadName() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-index-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let index = directory.appendingPathComponent("session_index.jsonl")
    try #"{"id":"thread-a","thread_name":"rework the importer so that it re"}"#
        .write(to: index, atomically: true, encoding: .utf8)

    let counter = ChangeCounter()
    let watcher = CodexSessionIndexWatcher(url: index, debounce: .milliseconds(50)) {
        counter.count += 1
    }
    watcher.start()
    defer { watcher.stop() }

    let handle = try FileHandle(forWritingTo: index)
    defer { try? handle.close() }
    handle.seekToEndOfFile()
    handle.write(Data(#"\#n{"id":"thread-a","thread_name":"Rework history importer"}"#.utf8))
    try handle.synchronize()

    #expect(await waitFor { counter.count > 0 })
}

@MainActor
@Test func codexIndexWatcherCoalescesABurstOfAppends() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-index-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let index = directory.appendingPathComponent("session_index.jsonl")
    try "".write(to: index, atomically: true, encoding: .utf8)

    let counter = ChangeCounter()
    let watcher = CodexSessionIndexWatcher(url: index, debounce: .milliseconds(300)) {
        counter.count += 1
    }
    watcher.start()
    defer { watcher.stop() }

    let handle = try FileHandle(forWritingTo: index)
    defer { try? handle.close() }
    for row in 0..<5 {
        handle.seekToEndOfFile()
        handle.write(Data(#"{"id":"thread-\#(row)","thread_name":"Row \#(row)"}\#n"#.utf8))
        try handle.synchronize()
        try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(await waitFor { counter.count > 0 })
    // The burst lands inside one debounce window, so it costs one import.
    #expect(counter.count == 1)
}

@MainActor
@Test func codexIndexWatcherStaysQuietWithoutAnIndexFile() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-index-watch-\(UUID().uuidString)")

    let counter = ChangeCounter()
    let watcher = CodexSessionIndexWatcher(
        url: directory.appendingPathComponent("session_index.jsonl"),
        debounce: .milliseconds(50)
    ) {
        counter.count += 1
    }
    watcher.start()
    defer { watcher.stop() }

    try? await Task.sleep(for: .milliseconds(150))
    #expect(counter.count == 0)
}
