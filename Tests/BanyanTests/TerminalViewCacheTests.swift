import AppKit
import BanyanCore
import Testing
@testable import Banyan
@testable import SwiftTerm

/// A real workload, with no access to the application's socket, database, or home.
@MainActor
private final class TerminalCacheFixture {
    let home: URL
    let host: HostRuntimeContext
    let backend: TmuxBackend
    let telemetry: PerformanceTelemetry
    let sessions: [TerminalSession]
    let switcher = TerminalSwitcherContainer(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
    let window: NSWindow

    init(count: Int = 24, home: URL? = nil) throws {
        let fixtureHome = home ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-cache-\(UUID().uuidString)")
        self.home = fixtureHome
        try FileManager.default.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["BANYAN_FIXTURE_DATA_HOME"] = fixtureHome.path
        environment["HOME"] = fixtureHome.path
        environment["SHELL"] = "/bin/sh"
        let host = HostRuntimeContext(environment: environment, homeDirectory: fixtureHome, currentDirectory: fixtureHome.path)
        self.host = host
        let backend = TmuxBackend(environment: environment, workingDirectory: fixtureHome.path,
                              socketName: "terminal-cache-\(UUID().uuidString)")
        self.backend = backend
        let telemetry = PerformanceTelemetry(store: PerformanceEventStore(databaseURL: PerformanceEventStore.defaultDatabaseURL(host: host)))
        self.telemetry = telemetry
        sessions = (0..<count).map { index in
            TerminalSession(id: "fixture-\(index)", title: "Fixture \(index)", cwd: fixtureHome.path,
                            command: "for i in $(seq 1 1500); do printf 'fixture-\(index)-line-%s\\n' \"$i\"; done; exec /bin/cat",
                            theme: .system, tmuxBackend: backend, telemetry: telemetry, host: host)
        }
        window = NSWindow(contentRect: switcher.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = switcher
        for session in sessions {
            session.onOutput = { [weak session] _ in
                guard let session else { return }
                session.telemetry.noteSessionFirstOutput(sessionID: session.id)
            }
        }
    }

    func select(_ session: TerminalSession, startClient: Bool = true) {
        telemetry.beginSessionSwitch(from: nil, to: session.id, visibleSessionCount: sessions.count)
        switcher.switchImmediately(to: session.id, selectionChangedAt: .now(), clickAt: nil)
        switcher.update(switchRequestedAt: .now(), selectionChangedAt: .now(), clickAt: nil,
                        sessions: sessions, selectedSessionID: session.id, theme: .system,
                        fontFamily: "Menlo", fontSize: 13, focusRequestID: UUID(),
                        onUserSubmittedInput: { _, _ in }, onTerminalReady: { session in
                            session.telemetry.noteSessionTerminalReady(sessionID: session.id)
                            if startClient { session.startAsync() }
                        })
        switcher.layoutSubtreeIfNeeded()
    }

    func tearDown(removeHome: Bool = true) {
        for session in sessions { session.killBackingSession() }
        switcher.update(switchRequestedAt: nil, selectionChangedAt: nil, clickAt: nil,
                        sessions: [], selectedSessionID: nil, theme: .system,
                        fontFamily: "Menlo", fontSize: 13, focusRequestID: UUID(),
                        onUserSubmittedInput: { _, _ in }, onTerminalReady: { _ in })
        window.close()
        telemetry.flushPendingEventsAndWait()
        if removeHome { try? FileManager.default.removeItem(at: home) }
    }
}

@Suite(.serialized)
@MainActor
struct TerminalViewCacheTests {
    @Test func twentyFourLiveSessionsStayBoundedAcrossRepeatedVisits() async throws {
        let fixture = try TerminalCacheFixture()
        defer { fixture.tearDown() }
        var evictedClients: [pid_t] = []
        var terminals: [WeakCachedObject<Terminal>] = []
        for _ in 0..<2 {
            for session in fixture.sessions {
                fixture.select(session)
                try #require(await cacheWait { session.loadedTerminalView?.process.running == true })
                evictedClients.append(try #require(session.loadedTerminalView?.process.shellPid))
                terminals.append(WeakCachedObject(try #require(session.loadedTerminalView?.terminal)))
                #expect(fixture.sessions.filter { $0.loadedTerminalView != nil }.count <= 4)
                #expect(fixture.switcher.subviews.count <= 4)
                #expect(fixture.switcher.subviews.filter { !$0.isHidden }.count == 1)
            }
            #expect(fixture.backend.listBanyanSessions().count == 24)
            #expect(await cacheWait { terminals.filter { $0.value != nil }.count == 4 },
                    "reset/reattach retained an evicted terminal's buffers")
        }
        let retainedPIDs = Set(fixture.sessions.compactMap { $0.loadedTerminalView?.process.shellPid })
        try #require(await cacheWait {
            evictedClients.filter { !retainedPIDs.contains($0) }.allSatisfy(clientWasCollected)
        }, "eviction left live or zombie attach children")
    }

    @Test func recentlySelectedTerminalSurvivesAndEvictedObjectsAreReleased() async throws {
        let fixture = try TerminalCacheFixture(count: 5)
        defer { fixture.tearDown() }
        for session in fixture.sessions.prefix(4) { fixture.select(session, startClient: false) }
        let oldView = WeakCachedObject(try #require(fixture.sessions[1].loadedTerminalView))
        let oldContainer = WeakCachedObject(try #require(fixture.switcher.subviews.compactMap { $0 as? TerminalContainerView }
            .first { $0.session === fixture.sessions[1] }))
        let recentView = fixture.sessions[0].loadedTerminalView
        fixture.select(fixture.sessions[0], startClient: false)
        fixture.select(fixture.sessions[4], startClient: false)
        #expect(fixture.sessions[0].loadedTerminalView === recentView)
        #expect(fixture.sessions[1].loadedTerminalView == nil)
        #expect(await cacheWait { oldView.value == nil && oldContainer.value == nil })
        fixture.switcher.terminalViewCacheLimit = 2
        #expect(fixture.sessions.filter { $0.loadedTerminalView != nil }.count == 2)
        #expect(fixture.sessions[4].loadedTerminalView != nil)
    }

    @Test func revisitPreservesPaneScreenCopyModeInputAndStatus() async throws {
        let fixture = try TerminalCacheFixture(count: 5)
        defer { fixture.tearDown() }
        let first = fixture.sessions[0]
        fixture.select(first)
        try #require(await cacheWait { terminalText(first).contains("fixture-0-line-1500") })
        let pane = try #require(fixture.backend.primaryPaneSnapshot(named: first.tmuxSessionName))
        first.status = .executing
        first.tone = .yellow
        let scrollPosition = await withCheckedContinuation { continuation in
            first.scrollHistory(paneID: pane.paneID, lines: 100, up: true) { continuation.resume(returning: $0) }
        }
        #expect(scrollPosition > 0)
        #expect(fixture.backend.primaryPaneSnapshot(named: first.tmuxSessionName)?.isInMode == true)
        let oldView = WeakCachedObject(try #require(first.loadedTerminalView))
        let oldClientPID = try #require(first.loadedTerminalView?.process.shellPid)
        for session in fixture.sessions.dropFirst() {
            fixture.select(session)
            try #require(await cacheWait { session.loadedTerminalView?.process.running == true })
        }
        #expect(first.loadedTerminalView == nil)
        #expect(first.isProcessStarted)
        #expect(first.status == .executing)
        #expect(first.tone == .yellow)
        #expect(await cacheWait { oldView.value == nil && clientWasCollected(oldClientPID) })

        fixture.select(first)
        try #require(await cacheWait { first.loadedTerminalView?.hasVisibleText == true })
        #expect(fixture.backend.primaryPaneSnapshot(named: first.tmuxSessionName)?.rootPID == pane.rootPID)
        #expect(fixture.backend.primaryPaneSnapshot(named: first.tmuxSessionName)?.isInMode == true)
        #expect(first.status == .executing)
        #expect(first.tone == .yellow)
        let bottom = await withCheckedContinuation { continuation in
            first.scrollHistory(paneID: pane.paneID, lines: 10_000, up: false) { continuation.resume(returning: $0) }
        }
        #expect(bottom == 0)
        try #require(await cacheWait { terminalText(first).contains("fixture-0-line-1500") })
        let view = try #require(first.loadedTerminalView)
        let input = Array("input-after-eviction\r".utf8)
        view.send(source: view, data: input[...])
        #expect(await cacheWait { terminalText(first).contains("input-after-eviction") })
        #expect(fixture.backend.captureCurrentVisibleText(paneID: pane.paneID).contains("input-after-eviction"))
    }

    @Test func deferredProjectSwitchProtectsSourceAndTargetUnderPressure() async throws {
        let fixture = try TerminalCacheFixture(count: 3)
        defer { fixture.tearDown() }
        fixture.switcher.terminalViewCacheLimit = 2
        for (index, session) in fixture.sessions.enumerated() { session.projectGroupID = "project-\(index)" }
        fixture.select(fixture.sessions[0], startClient: false)
        fixture.select(fixture.sessions[1], startClient: false)
        #expect(fixture.sessions[0].loadedTerminalView != nil)
        #expect(fixture.sessions[1].loadedTerminalView != nil)
        fixture.select(fixture.sessions[2], startClient: false)
        #expect(fixture.sessions[0].loadedTerminalView != nil)
        #expect(fixture.sessions[1].loadedTerminalView == nil)
        #expect(fixture.sessions[2].loadedTerminalView != nil)
        #expect(await cacheWait {
            fixture.switcher.subviews.compactMap { $0 as? TerminalContainerView }
                .first { !$0.isHidden }?.session === fixture.sessions[2]
        })
        fixture.select(fixture.sessions[0], startClient: false)
        #expect(await cacheWait {
            fixture.switcher.subviews.compactMap { $0 as? TerminalContainerView }
                .first { !$0.isHidden }?.session === fixture.sessions[0]
        })
    }

    @Test func cancellingBackToSourceMakesItMostRecentlySelected() throws {
        let fixture = try TerminalCacheFixture(count: 3)
        defer { fixture.tearDown() }
        fixture.switcher.terminalViewCacheLimit = 2
        fixture.sessions[0].projectGroupID = "project-a"
        fixture.sessions[1].projectGroupID = "project-b"
        fixture.sessions[2].projectGroupID = "project-a"
        fixture.select(fixture.sessions[0], startClient: false)
        fixture.select(fixture.sessions[1], startClient: false)
        fixture.select(fixture.sessions[0], startClient: false)
        fixture.select(fixture.sessions[2], startClient: false)
        #expect(fixture.sessions[0].loadedTerminalView != nil)
        #expect(fixture.sessions[1].loadedTerminalView == nil)
        #expect(fixture.sessions[2].loadedTerminalView != nil)
    }

    @Test func evictionCancelsPendingReadinessAndIgnoresOldDelegateEvents() async throws {
        let fixture = try TerminalCacheFixture(count: 3)
        defer { fixture.tearDown() }
        fixture.window.contentView = nil
        fixture.switcher.terminalViewCacheLimit = 2
        let first = fixture.sessions[0]
        fixture.select(first)
        let container = try #require(fixture.switcher.subviews.first as? TerminalContainerView)
        let oldView = try #require(first.loadedTerminalView)
        // Queue notifications while the old view is still the current source.
        first.delegate?.processTerminated(source: oldView, exitCode: 1)
        first.delegate?.setTerminalTitle(source: oldView, title: "Stale terminal title")
        fixture.select(fixture.sessions[1], startClient: false)
        fixture.select(fixture.sessions[2], startClient: false)
        #expect(first.loadedTerminalView == nil)
        // AppKit retaining/reparenting an old container must never revive its callback.
        fixture.window.contentView = container
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(first.loadedTerminalView == nil)
        #expect(!first.isProcessStarted)
        #expect(first.status == .running)
        #expect(first.reportedTitle != "Stale terminal title")
        #expect(!fixture.backend.hasSession(named: first.tmuxSessionName))
    }

    @Test(arguments: [false, true])
    func unloadingRejectsPendingAttachSuccessAndFailure(fails: Bool) async throws {
        let fixture = try TerminalCacheFixture(count: 1)
        defer { fixture.tearDown() }
        let backend = DelayedCacheBackend(fails: fails)
        let session = TerminalSession(id: "delayed", title: "Delayed", cwd: fixture.home.path,
                                      command: "", theme: .system, tmuxBackend: backend,
                                      telemetry: fixture.telemetry, host: fixture.host)
        _ = session.terminalView
        session.startAsync()
        defer { backend.unblock.signal(); session.stopTerminalClient() }
        let didEnter = await Task.detached { backend.waitForEntry() }.value
        try #require(didEnter)
        session.unloadTerminalView()
        let replacement = session.terminalView
        session.status = .executing
        backend.unblock.signal()
        let didFinish = await Task.detached { backend.waitForCompletion() }.value
        try #require(didFinish)
        // Allow the main-actor completion queued by the background ensure to run.
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.loadedTerminalView === replacement)
        #expect(!replacement.process.running)
        #expect(!session.isProcessStarted)
        #expect(session.status == .executing)
        #expect(session.pendingTerminalMessage == nil)
    }
}

private final class WeakCachedObject<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// A barrier at the actual async ensure boundary, for deterministic stale-work tests.
private final class DelayedCacheBackend: TmuxClientBackend, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let unblock = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let fails: Bool
    let executableURL = URL(fileURLWithPath: "/bin/cat")

    init(fails: Bool) { self.fails = fails }
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 10) == .success }
    func waitForCompletion() -> Bool { finished.wait(timeout: .now() + 10) == .success }
    func hasSession(named name: String) -> Bool { false }
    func ensureSession(named name: String, cwd: String, command: String, banyanSessionID: String?) throws {
        entered.signal()
        unblock.wait()
        defer { finished.signal() }
        if fails { throw CocoaError(.fileNoSuchFile) }
    }
    func killSession(named name: String) {}
    func primaryPaneSnapshot(named name: String) -> TmuxPaneSnapshot? { nil }
    func captureVisibleText(paneID: String, lineLimit: Int) -> String { "" }
    func captureCurrentVisibleText(paneID: String) -> String { "" }
    func attachArguments(for name: String) -> [String] { [] }
    func configureTerminalTheme(style: String, for sessionName: String?) {}
    func refreshClients(attachedTo name: String) {}
    func scrollHistory(paneID: String, lines: Int, up: Bool, onScrollPosition: (@Sendable (Int) -> Void)?) {}
}

private func clientWasCollected(_ pid: pid_t) -> Bool {
    // Unlike waitpid, this observes zombies without accidentally reaping them.
    kill(pid, 0) == -1 && errno == ESRCH
}

@MainActor
private func terminalText(_ session: TerminalSession) -> String {
    guard let terminal = session.loadedTerminalView?.terminal else { return "" }
    return (0..<terminal.rows).map { terminal.buffer.lines[terminal.buffer.yDisp + $0]
        .translateToString(trimRight: true) }.joined(separator: "\n")
}

/// Opt-in so heap/vmmap sampling never makes the normal regression suite slow.
/// The driver acknowledges each phase after sampling this process externally.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["BANYAN_TERMINAL_CACHE_BENCH_DIR"] != nil))
func terminalViewCacheMemoryWorkload() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["BANYAN_TERMINAL_CACHE_BENCH_DIR"]))
    let fixture = try TerminalCacheFixture(home: root.appendingPathComponent("data"))
    defer { fixture.tearDown(removeHome: false) }
    if let limit = ProcessInfo.processInfo.environment["BANYAN_TERMINAL_CACHE_BENCH_LIMIT"].flatMap(Int.init) {
        fixture.switcher.terminalViewCacheLimit = limit
    }
    try JSONSerialization.data(withJSONObject: ["socket": fixture.backend.socketName,
                                               "tmux": fixture.backend.executableURL.path])
        .write(to: root.appendingPathComponent("runtime.json"))
    fixture.window.orderFront(nil)
    for cycle in 1...3 {
        for session in fixture.sessions {
            fixture.select(session)
            try #require(await cacheWait { session.loadedTerminalView?.hasVisibleText == true })
            // Ensure AppKit has an opportunity to paint and allocate the backing surface.
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .seconds(1))
        fixture.telemetry.flushPendingEventsAndWait()
        let phase = "cycle-\(cycle)"
        let snapshot: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                                      "loaded": fixture.sessions.filter { $0.loadedTerminalView != nil }.count,
                                      "containers": fixture.switcher.subviews.count, "phase": phase]
        try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("\(phase).json"))
        try #require(await cacheWait(seconds: 90) {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("\(phase).continue").path)
        }, "measurement driver did not acknowledge \(phase)")
    }
}

@MainActor
private func cacheWait(seconds: TimeInterval = 10, until predicate: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return predicate()
}
