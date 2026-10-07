import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BanyanCore

private let fakeServer = #"""
#!/usr/bin/env python3
import json, os, sys, threading, time, signal
if os.environ.get("FAKE_CODEX_IGNORE_TERM"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
pid_list = os.environ.get('FAKE_CODEX_PID_LIST')
if pid_list:
    with open(pid_list, 'a') as file: file.write(str(os.getpid()) + '\n')
pid_file = os.environ.get("FAKE_CODEX_PID_FILE")
if pid_file:
    with open(pid_file, "w") as file: file.write(str(os.getpid()))

lock = threading.Lock()
launch_file = os.environ.get('FAKE_CODEX_LAUNCH_FILE')
if launch_file:
    with open(launch_file, 'a') as file:
        file.write('start\n')

def send(message):
    with lock:
        print(json.dumps(message), flush=True)

waiting = None
initialized = False
for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    identifier = message.get('id')
    if method == 'initialize':
        time.sleep(float(os.environ.get('FAKE_CODEX_INITIALIZE_DELAY', '0')))
        if os.environ.get('FAKE_CODEX_STALL_INITIALIZE'): continue
        version = os.environ.get('FAKE_CODEX_VERSION', '0.146.0')
        result = {'userAgent': 'banyan/' + version + ' (test)', 'platformFamily': 'unix', 'platformOs': 'macos'}
        if os.environ.get('FAKE_CODEX_REPORTED_HOME'): result['codexHome'] = os.environ['FAKE_CODEX_REPORTED_HOME']
        send({'id': identifier, 'result': result})
    elif method == 'initialized':
        initialized = True
    elif not initialized:
        send({'id': identifier, 'error': {'code': -32000, 'message': 'Not initialized'}})
    elif method == 'echo':
        value = message['params']['value']
        delay = message['params'].get('delay', 0)
        threading.Timer(delay, lambda identifier=identifier, value=value: send({'id': identifier, 'result': {'value': value}})).start()
    elif method == 'event':
        send({'method': 'turn/started', 'params': {'threadId': 'thread-test'}})
        send({'id': identifier, 'result': {}})
    elif method == 'ask':
        waiting = identifier
        send({'id': 'server-request-1', 'method': 'item/commandExecution/requestApproval', 'params': {'threadId': 'thread-test'}})
    elif identifier == 'server-request-1':
        send({'id': waiting, 'result': message.get('result', message.get('error'))})
        waiting = None
    elif method == 'crash':
        os._exit(7)
    else:
        send({'id': identifier, 'error': {'code': -32601, 'message': 'unknown method'}})
if os.environ.get("FAKE_CODEX_IGNORE_TERM"):
    while True: time.sleep(1)
"""#

private struct FakeServerFixture {
    let directory: URL
    let executable: URL
    let launchFile: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-codex")
        launchFile = directory.appendingPathComponent("launches.txt")
        try fakeServer.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func client(version: String = "0.146.0", ignoreTermination: Bool = false, initializeDelay: Double = 0) -> CodexAppServerClient {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CODEX_LAUNCH_FILE"] = launchFile.path
        environment["FAKE_CODEX_VERSION"] = version
        environment["FAKE_CODEX_INITIALIZE_DELAY"] = String(initializeDelay)
        environment["FAKE_CODEX_PID_LIST"] = directory.appendingPathComponent("pids").path
        environment["FAKE_CODEX_PID_FILE"] = directory.appendingPathComponent("pid").path
        if ignoreTermination { environment["FAKE_CODEX_IGNORE_TERM"] = "1" }
        return CodexAppServerClient(
            executable: executable.path,
            environment: environment,
            requestTimeout: 10
        )
    }

    var launchCount: Int {
        let contents = (try? String(contentsOf: launchFile, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").count
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func appServerStorageProvenanceUsesResolvedLaunchEnvironment() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    var rawHost = ProcessInfo.processInfo.environment
    rawHost["CODEX_HOME"] = "/tmp/raw-host-store"
    var resolvedShell = rawHost
    resolvedShell["CODEX_HOME"] = fixture.directory.appendingPathComponent("resolved-shell-store").path
    let effectiveEnvironment = resolvedShell
    let client = CodexAppServerClient(executable: fixture.executable.path, environment: rawHost,
        environmentProvider: { effectiveEnvironment }, requestTimeout: 10)
    #expect(await client.storageHome() == resolvedShell["CODEX_HOME"])
    try await client.connect()
    #expect(await client.storageHome() == resolvedShell["CODEX_HOME"])
    try await client.disconnectForHandoff()
    #expect(await client.storageHome() == resolvedShell["CODEX_HOME"])
    await client.stop()
}

@Test func appServerSharesOneChildAndRoutesInterleavedResponses() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client()
    let values = try await withThrowingTaskGroup(of: String.self) { group in
        for index in 0..<12 {
            group.addTask {
                let result = try await client.request("echo", params: .object([
                    "value": .string("value-\(index)"),
                    "delay": .number(index.isMultiple(of: 2) ? 0.05 : 0)
                ]))
                return result.objectValue?["value"]?.stringValue ?? "missing"
            }
        }
        var result: [String] = []
        for try await value in group { result.append(value) }
        return result
    }
    #expect(Set(values) == Set((0..<12).map { "value-\($0)" }))
    #expect(fixture.launchCount == 1)
    await client.stop()
}

@Test func appServerRoutesNotificationsAndServerRequests() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client()
    let events = await client.events()
    await client.setServerRequestHandler { request in
        #expect(request.method == "item/commandExecution/requestApproval")
        return .result(.object(["decision": .string("decline")]))
    }
    let answer = try await client.request("ask")
    #expect(answer.objectValue?["decision"]?.stringValue == "decline")
    _ = try await client.request("event")
    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    if case .notification(let method, let params) = event {
        #expect(method == "turn/started")
        #expect(params.objectValue?["threadId"]?.stringValue == "thread-test")
    } else {
        Issue.record("Expected a notification")
    }
    await client.stop()
}

@Test func appServerReportsExitThenReconnectsOnNextOperation() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client()
    let events = await client.events()
    do {
        _ = try await client.request("crash")
        Issue.record("Expected the child exit to fail its in-flight request")
    } catch let error as CodexAppServerError {
        guard case .disconnected = error else {
            Issue.record("Expected disconnected, got \(error)")
            return
        }
    }
    var iterator = events.makeAsyncIterator()
    let event = await iterator.next()
    if case .disconnected = event {} else { Issue.record("Expected exit event") }
    let result = try await client.request("echo", params: .object(["value": .string("recovered")]))
    #expect(result.objectValue?["value"]?.stringValue == "recovered")
    #expect(fixture.launchCount == 2)
    await client.stop()
}

@Test func appServerRejectsUntestedProtocolVersion() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client(version: "0.147.0")
    do {
        try await client.connect()
        Issue.record("Expected incompatible version")
    } catch let error as CodexAppServerError {
        #expect(error == .incompatibleVersion("0.147.0"))
    }
    await client.stop()
}

@Test func appServerAcceptsTestedCurrentVersionAndCanReconnectAfterCLIHandoff() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client(version: "0.160.0")
    try await client.connect()
    try await client.disconnectForHandoff()
    let result = try await client.request("echo", params: .object(["value": .string("native again")]))
    #expect(result.objectValue?["value"]?.stringValue == "native again")
    #expect(fixture.launchCount == 2)
    await client.stop()
}

@Test func appServerRejectsUnknownVersionsAndReapsEvenAnUncooperativeChild() async throws {
    for version in ["0.160.1", "0.999.0", "invalid"] {
        let fixture = try FakeServerFixture()
        defer { fixture.cleanup() }
        let client = fixture.client(version: version, ignoreTermination: true)
        do {
            try await client.connect()
            Issue.record("Expected unsupported or malformed version")
        } catch {
            #expect(error.localizedDescription.contains("CLI fallback") || error.localizedDescription.contains("recognizable server version"))
        }
        let pid = try #require(Int32(String(contentsOf: fixture.directory.appendingPathComponent("pid"), encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        await client.stop()
    }
}

@Test func appServerExistingTurnActionNeverReconnectsAfterConnectionWasReleased() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client()
    try await client.connect()
    try await client.disconnectForHandoff()
    await #expect(throws: CodexAppServerError.self) {
        try await client.requestWhileConnected("echo", params: .object(["value": .string("disabled")]))
    }
    #expect(fixture.launchCount == 1)
    await client.stop()
}

@Test func appServerPrefersServerReportedHomeAndReapsAStalledStartup() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = "/tmp/launch-store"
    environment["FAKE_CODEX_REPORTED_HOME"] = "/tmp/server-reported-store"
    let client = CodexAppServerClient(executable: fixture.executable.path, environment: environment, requestTimeout: 10)
    try await client.connect()
    #expect(await client.storageHome() == "/tmp/server-reported-store")
    await client.stop()

    environment["FAKE_CODEX_STALL_INITIALIZE"] = "1"
    environment["FAKE_CODEX_IGNORE_TERM"] = "1"
    environment["FAKE_CODEX_PID_FILE"] = fixture.directory.appendingPathComponent("stalled-pid").path
    let stalled = CodexAppServerClient(executable: fixture.executable.path, environment: environment, requestTimeout: 1)
    do {
        try await stalled.connect()
        Issue.record("Expected initialize timeout")
    } catch { #expect(error as? CodexAppServerError == .timedOut("initialize")) }
    let pid = try #require(Int32(String(contentsOf: fixture.directory.appendingPathComponent("stalled-pid"), encoding: .utf8)))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
    await stalled.stop()
}

@Test func appServerHandoffDuringStartupKeepsTheReplacementConnectionCoalescedAndReapsAllChildren() async throws {
    let fixture = try FakeServerFixture()
    defer { fixture.cleanup() }
    let client = fixture.client(initializeDelay: 0.25)
    let first = Task { try await client.connect() }
    for _ in 0..<200 {
        if fixture.launchCount > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.launchCount == 1)
    try await client.disconnectForHandoff()
    do { try await first.value; Issue.record("Interrupted handshake should fail") } catch {}
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask {
                _ = try await client.request("echo", params: .object(["value": .string("replacement")]))
            }
        }
        try await group.waitForAll()
    }
    #expect(fixture.launchCount == 2)
    await client.stop()
    let pids = try String(contentsOf: fixture.directory.appendingPathComponent("pids"), encoding: .utf8)
        .split(separator: "\n").compactMap { Int32($0) }
    #expect(pids.count == 2)
    for pid in pids { #expect(kill(pid, 0) == -1); #expect(errno == ESRCH) }
}
