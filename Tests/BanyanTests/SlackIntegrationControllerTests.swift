import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

private final class MemorySlackCredentials: SlackCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: SlackCredentials?
    private var gate: DispatchSemaphore?
    private var started = false
    var loadStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func holdNextLoad() -> DispatchSemaphore {
        lock.lock(); defer { lock.unlock() }
        let result = DispatchSemaphore(value: 0); gate = result; started = false; return result
    }
    func save(_ credentials: SlackCredentials) throws { lock.lock(); defer { lock.unlock() }; pair = credentials }
    func load() throws -> SlackCredentials {
        lock.lock()
        let value = pair, waiting = gate
        if waiting != nil { started = true; gate = nil }
        lock.unlock()
        if let waiting { _ = waiting.wait(timeout: .now() + 5) }
        guard let value else { throw SlackCredentialError.invalid }
        return value
    }
}

@MainActor
private final class FakeSlackChild: SlackConnectorRunning {
    var terminationCount = 0
    func terminate() { terminationCount += 1 }
}

@MainActor
private final class FakeSlackLauncher: SlackConnectorLaunching {
    struct Launch {
        let specification: SlackConnectorLaunch
        let child: FakeSlackChild
        let status: @MainActor (String) -> Void
        let exited: @MainActor (Int32) -> Void
    }
    var launches: [Launch] = []
    func launch(_ specification: SlackConnectorLaunch, status: @escaping @MainActor (String) -> Void,
                exited: @escaping @MainActor (Int32) -> Void) throws -> any SlackConnectorRunning {
        let child = FakeSlackChild()
        launches.append(.init(specification: specification, child: child, status: status, exited: exited))
        return child
    }
}

@Suite(.serialized)
@MainActor
struct SlackIntegrationControllerTests {
    private let principal = CodexRemotePrincipal(workspace: "TTEST", channel: "CTEST", user: "UTEST")

    @Test func credentialsStayInStoreAndLifecycleDoesNotDuplicateChildren() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        let script = fixture.root.appendingPathComponent("connector.py")
        try Data("fixture".utf8).write(to: script)
        let credentials = MemorySlackCredentials()
        let launcher = FakeSlackLauncher()
        let suiteName = "banyan_slack_test_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SlackIntegrationController(remote: store.codexRemote, host: store.host, script: script,
            credentials: credentials, launcher: launcher, pythonPath: "/usr/bin/true", controlURL: "http://127.0.0.1:1",
            tokenFile: fixture.root.appendingPathComponent("token"), pythonDefaults: defaults,
            pythonDefaultsKey: "python", managedDefaultsKey: "managed")
        controller.controlServerBecameReady(port: 43210)
        try controller.setAllowlist([principal])
        try await controller.saveCredentials(botToken: "fixture-bot-secret", appToken: "fixture-app-secret")
        #expect(try credentials.load().botToken == "fixture-bot-secret")
        try await controller.start()
        #expect(launcher.launches.count == 1 && controller.enabled)
        #expect(controller.connection == .connecting)
        let spec = launcher.launches[0].specification
        #expect(spec.environment["SLACK_BOT_TOKEN"] == "fixture-bot-secret")
        #expect(spec.environment["SLACK_APP_TOKEN"] == "fixture-app-secret")
        #expect(!spec.arguments.contains(where: { $0.contains("fixture-bot-secret") || $0.contains("fixture-app-secret") }))
        #expect(spec.arguments.contains("http://127.0.0.1:43210"))
        let policyIndex = try #require(spec.arguments.firstIndex(of: "--config"))
        let policy = try String(contentsOfFile: spec.arguments[policyIndex + 1], encoding: .utf8)
        #expect(!policy.contains("fixture-bot-secret") && !policy.contains("fixture-app-secret"))
        #expect(defaults.bool(forKey: "managed"))
        launcher.launches[0].status("connected")
        #expect(controller.connection == .connected)
        try await controller.start()
        #expect(launcher.launches.count == 1)
        try controller.reconnect()
        #expect(launcher.launches[0].child.terminationCount == 1 && !store.codexRemote.policy.enabled)
        try await controller.start() // The old child still owns its lifecycle.
        #expect(launcher.launches.count == 1)
        launcher.launches[0].exited(0)
        try await waitForPuckState { launcher.launches.count == 2 }
        #expect(store.codexRemote.policy.enabled)
        launcher.launches[0].status("connected") // Retired child cannot update state.
        #expect(controller.connection == .connecting)
        launcher.launches[1].status("connected")
        #expect(controller.connection == .connected)
        try controller.stop()
        #expect(!store.codexRemote.policy.enabled && launcher.launches[1].child.terminationCount == 1)
        launcher.launches[1].exited(0)
        #expect(controller.connection == .disabled)
    }

    @Test func disablingDuringCredentialLoadCannotStartAChild() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        let script = fixture.root.appendingPathComponent("connector.py")
        try Data("fixture".utf8).write(to: script)
        let credentials = MemorySlackCredentials()
        let launcher = FakeSlackLauncher()
        let controller = SlackIntegrationController(remote: store.codexRemote, host: store.host, script: script,
            credentials: credentials, launcher: launcher, pythonPath: "/usr/bin/true", controlURL: "http://127.0.0.1:1",
            tokenFile: fixture.root.appendingPathComponent("token"))
        controller.controlServerBecameReady(port: 43210)
        try controller.setAllowlist([principal])
        try await controller.saveCredentials(botToken: "fixture-bot-secret", appToken: "fixture-app-secret")
        let gate = credentials.holdNextLoad()
        defer { gate.signal() }
        let start = Task { try await controller.start() }
        try await waitForPuckState { credentials.loadStarted }
        try controller.stop()
        gate.signal()
        try await start.value
        #expect(launcher.launches.isEmpty && !store.codexRemote.policy.enabled)
        #expect(controller.connection == .disabled)
    }

    @Test func localLauncherReportsOnlyRecognizedStatusAndObservesExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slack_launcher_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fixture.py")
        try Data("""
        import signal, sys
        print('unknown fixture-secret', flush=True)
        print('BANYAN_SLACK_STATUS=connecting', flush=True)
        print('BANYAN_SLACK_STATUS=connected', flush=True)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True: signal.pause()
        """.utf8).write(to: script)
        var statuses: [String] = []
        var exitCode: Int32?
        let child = try LocalSlackConnectorLauncher().launch(.init(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [script.path], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: directory),
            status: { statuses.append($0) }, exited: { exitCode = $0 })
        defer { child.terminate() }
        try await waitForPuckState { statuses.contains("connected") }
        #expect(statuses == ["connecting", "connected"])
        #expect(!statuses.contains(where: { $0.contains("fixture-secret") }))
        child.terminate()
        try await waitForPuckState { exitCode != nil }
        #expect(exitCode == 0)
    }

    @Test func integrationRejectsMultipleChannelsAndDoesNotAutoStartLegacyPolicy() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = fixture.makeStore()
        let script = fixture.root.appendingPathComponent("connector.py")
        try Data("fixture".utf8).write(to: script)
        let credentials = MemorySlackCredentials()
        let launcher = FakeSlackLauncher()
        let controller = SlackIntegrationController(remote: store.codexRemote, host: store.host, script: script,
            credentials: credentials, launcher: launcher, pythonPath: "/usr/bin/true", controlURL: "http://127.0.0.1:1",
            tokenFile: fixture.root.appendingPathComponent("token"))
        let other = CodexRemotePrincipal(workspace: "TTEST", channel: "COTHER", user: "UOTHER")
        #expect(throws: SlackIntegrationController.Failure.self) { try controller.setAllowlist([principal, other]) }
        try store.codexRemote.configure(.init(enabled: true, allowed: [principal]))
        controller.policyChanged()
        controller.controlServerBecameReady(port: 43210)
        await Task.yield()
        #expect(launcher.launches.isEmpty)
        #expect(controller.connection == .disabled || controller.connection == .stopped)
    }
}
