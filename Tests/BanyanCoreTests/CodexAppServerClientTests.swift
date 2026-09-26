import Foundation
import Testing
@testable import BanyanCore

private let fakeServer = #"""
#!/usr/bin/env python3
import json, os, sys, threading, time

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
        version = os.environ.get('FAKE_CODEX_VERSION', '0.146.0')
        send({'id': identifier, 'result': {'userAgent': 'banyan/' + version + ' (test)', 'platformFamily': 'unix', 'platformOs': 'macos'}})
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

    func client(version: String = "0.146.0") -> CodexAppServerClient {
        var environment = ProcessInfo.processInfo.environment
        environment["FAKE_CODEX_LAUNCH_FILE"] = launchFile.path
        environment["FAKE_CODEX_VERSION"] = version
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
