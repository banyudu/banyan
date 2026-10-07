import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BanyanCore

/// Per-session fake networks keep concurrently running tests isolated. No live
/// API, user config, environment variables or running terminal sessions are used.
final class TelemetryFakeNetwork: @unchecked Sendable {
    enum Reply {
        case status(Int, String)
        case failure(URLError)
        case held
    }
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var replies: [Reply]
    let id = UUID().uuidString
    let session: URLSession

    init(_ replies: [Reply] = []) {
        self.replies = replies
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Network": id]
        session = URLSession(configuration: configuration)
        TelemetryURLProtocol.register(self, id: id)
    }

    deinit {
        session.invalidateAndCancel()
        TelemetryURLProtocol.unregister(id)
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    func receive(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let size = stream.read(&scratch, maxLength: scratch.count)
                guard size > 0 else { break }
                body.append(contentsOf: scratch.prefix(size))
            }
            capturedRequest.httpBody = body
        }
        captured.append(capturedRequest)
        return replies.isEmpty ? .status(200, "{}") : replies.removeFirst()
    }

    func exporter(batchSize: Int = 100, bufferLimit: Int = 1000, flushInterval: TimeInterval = 30) -> AxiomExporter {
        AxiomExporter(config: TelemetryConfig(axiomAPIToken: "xaat-fixture-token", axiomOrgID: "test-org", axiomDataset: "test-dataset"),
                      appVersion: "1.2.3", session: session, batchSize: batchSize,
                      bufferLimit: bufferLimit, flushInterval: flushInterval)
    }

    func spans() throws -> [[String: Any]] {
        try requests.filter { $0.url?.path == "/v1/traces" }.flatMap { request in
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let resources = try #require(json["resourceSpans"] as? [[String: Any]])
            let scopes = try #require(resources.first?["scopeSpans"] as? [[String: Any]])
            return try #require(scopes.first?["spans"] as? [[String: Any]])
        }
    }
}

private final class WeakNetwork: @unchecked Sendable {
    weak var value: TelemetryFakeNetwork?
    init(_ value: TelemetryFakeNetwork) { self.value = value }
}

private final class TelemetryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var networks: [String: WeakNetwork] = [:]
    static func register(_ network: TelemetryFakeNetwork, id: String) {
        lock.lock(); defer { lock.unlock() }; networks[id] = WeakNetwork(network)
    }
    static func unregister(_ id: String) {
        lock.lock(); defer { lock.unlock() }; networks.removeValue(forKey: id)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let network = Self.networks[request.value(forHTTPHeaderField: "X-Test-Network") ?? ""]?.value
        Self.lock.unlock()
        guard let network else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch network.receive(request) {
        case .held: break
        case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
        case .status(let status, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func attributes(_ span: [String: Any]) -> [String: String] {
    let entries = span["attributes"] as? [[String: Any]] ?? []
    return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
        guard let key = entry["key"] as? String,
              let value = entry["value"] as? [String: Any], let scalar = value.values.first else { return nil }
        return (key, String(describing: scalar))
    })
}

@Suite(.serialized) struct AxiomExporterTests {
    @Test func noTokenAndDisabledStartupDoNotInitializeExporterOrSend() async {
        for config in [TelemetryConfig(), .disabled,
                       TelemetryConfig(axiomAPIToken: "xaat-fixture", enabled: false),
                       TelemetryConfig(axiomAPIToken: "   "),
                       TelemetryConfig(axiomAPIToken: "xaat-test\r\nInjected: bad")] {
            #expect(AxiomExporter.configured(config: config) == nil)
            let network = TelemetryFakeNetwork()
            let exporter = AxiomExporter(config: config, session: network.session)
            #expect(exporter.startSpan("disabled") == nil)
            exporter.sendAppLifecycle("disabled")
            #expect(await exporter.shutdownAndWait() == AxiomExporter.ExportResult())
            #expect(network.requests.isEmpty)
        }
    }

    @Test func otlpPayloadHasValidParentContextTimingHeadersAndResource() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter()
        try await TraceContext.withSpan(exporter: exporter, name: "operation") {
            let first = try #require(exporter.startSpan("child"))
            first.end()
            first.end() // Ending twice must not emit duplicates.
            await Task { exporter.startSpan("task.child")?.end() }.value
        }
        #expect(TraceContext.current == nil)
        let result = await exporter.flushAndWait()
        #expect(result.exportedSpans == 3)
        let request = try #require(network.requests.first)
        #expect(request.url?.absoluteString == "https://api.axiom.co/v1/traces")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xaat-fixture-token")
        #expect(request.value(forHTTPHeaderField: "X-Axiom-Dataset") == "test-dataset")
        #expect(request.value(forHTTPHeaderField: "X-Axiom-Org-ID") == "test-org")
        let spans = try network.spans()
        let root = try #require(spans.first { $0["name"] as? String == "operation" })
        #expect(root["parentSpanId"] == nil)
        #expect(Set(spans.compactMap { $0["traceId"] as? String }).count == 1)
        #expect(Set(spans.compactMap { $0["spanId"] as? String }).count == 3)
        for span in spans {
            let trace = try #require(span["traceId"] as? String)
            let id = try #require(span["spanId"] as? String)
            #expect(trace.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
            #expect(id.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil)
            let startText = try #require(span["startTimeUnixNano"] as? String)
            let endText = try #require(span["endTimeUnixNano"] as? String)
            let start = try #require(UInt64(startText))
            let end = try #require(UInt64(endText))
            #expect(end >= start)
            #expect(span["kind"] as? Int == 1)
            if span["name"] as? String != "operation" {
                #expect(span["parentSpanId"] as? String == root["spanId"] as? String)
            }
        }
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let resource = try #require((payload["resourceSpans"] as? [[String: Any]])?.first?["resource"] as? [String: Any])
        #expect(attributes(resource)["service.name"] == "banyan")
        #expect(attributes(resource)["service.version"] == "1.2.3")
        _ = await exporter.shutdownAndWait()
    }

    @Test func httpSuccessFailureCancellationAndURLPrivacy() async throws {
        let network = TelemetryFakeNetwork([.status(201, "{}"), .status(503, "{}"), .failure(URLError(.cancelled))])
        let exporter = network.exporter()
        var request = URLRequest(url: URL(string: "https://user:password@example.test/private-token?token=secret#prompt")!)
        request.httpMethod = "POST"
        request.httpBody = Data("private-prompt".utf8)
        request.setValue("Bearer sensitive-auth", forHTTPHeaderField: "Authorization")
        try await TraceContext.withSpan(exporter: exporter, name: "api.operation") {
            _ = try await TracedHTTP.data(for: request, session: network.session, exporter: exporter, service: "test")
            _ = try await TracedHTTP.data(for: request, session: network.session, exporter: exporter, service: "test")
            do {
                _ = try await TracedHTTP.data(for: request, session: network.session, exporter: exporter, service: "test")
                Issue.record("Expected URLSession cancellation")
            } catch let error as URLError { #expect(error.code == .cancelled) }
        }
        _ = await exporter.shutdownAndWait()
        let spans = try network.spans()
        let http = spans.filter { $0["name"] as? String == "http.request" }
        #expect(http.count == 3)
        #expect(attributes(http[0])["http.request.method"] == "POST")
        #expect(attributes(http[0])["http.response.status_code"] == "201")
        let statusAttribute = (http[0]["attributes"] as? [[String: Any]])?.first { $0["key"] as? String == "http.response.status_code" }
        #expect((statusAttribute?["value"] as? [String: String])?["intValue"] == "201")
        #expect(attributes(http[0])["url.full"] == "https://example.test/")
        #expect(attributes(http[1])["http.response.status_code"] == "503")
        #expect((http[1]["status"] as? [String: Int])?["code"] == 2)
        #expect(attributes(http[2])["http.response.status_code"] == nil)
        #expect(attributes(http[2])["error.type"] == "url_error_-999")
        for (index, span) in http.enumerated() {
            let context = "00-\(span["traceId"]!)-\(span["spanId"]!)-01"
            #expect(network.requests[index].value(forHTTPHeaderField: "traceparent") == context)
        }
        let bytes = String(data: try #require(network.requests.last?.httpBody), encoding: .utf8)!
        for secret in ["private-token", "password", "private-prompt", "sensitive-auth", "token=secret"] {
            #expect(!bytes.contains(secret))
        }
        #expect(network.requests.filter { $0.url?.path == "/v1/traces" }.count == 1) // no recursion
    }

    @Test func disabledHTTPDoesNotInjectContextAndDownloadFailuresAreTraced() async throws {
        let network = TelemetryFakeNetwork([.status(200, "{}"), .failure(URLError(.timedOut))])
        let request = URLRequest(url: URL(string: "https://example.test/asset?signature=private")!)
        _ = try await TracedHTTP.data(for: request, session: network.session, exporter: nil, service: "github")
        #expect(network.requests.first?.value(forHTTPHeaderField: "traceparent") == nil)
        let exporter = network.exporter()
        do {
            _ = try await TracedHTTP.download(for: request, session: network.session, exporter: exporter, service: "github")
            Issue.record("Expected download failure")
        } catch let error as URLError { #expect(error.code == .timedOut) }
        _ = await exporter.shutdownAndWait()
        let span = try #require(network.spans().first)
        #expect(attributes(span)["error.type"] == "url_error_-1001")
        #expect(attributes(span)["url.full"] == "https://example.test/")
    }

    @Test func legacyFreeFormAttributesAreSanitizedAtExportBoundary() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter()
        exporter.send(TelemetryEvent(name: "diagnostic", category: "api", durationMS: .nan, attributes: [
            "authorization": "private-token", "command": "sh -c private-prompt",
            "detail": "private-terminal-text", "session_id": "private-session-label",
            "url.full": "https://user:private-password@example.test/private-path?token=private-query",
            "process.executable.name": "/private-path/private-tool",
        ]))
        exporter.sendHTTPRequest(service: "github", method: "CLI", url: "private-url",
                                 statusCode: 0, durationMS: 10, error: "private-stderr")
        _ = await exporter.shutdownAndWait()
        let body = String(data: try #require(network.requests.first?.httpBody), encoding: .utf8)!
        #expect(!body.contains("private"))
        let span = try #require(network.spans().first)
        #expect(attributes(span)["process.executable.name"] == "other")
        #expect(attributes(span)["url.full"] == "https://example.test/")
        #expect(Double(attributes(span)["duration_ms"] ?? "") == 0)
    }

    @Test func failuresAreBoundedAndPartialSuccessIsNotRetried() async throws {
        let network = TelemetryFakeNetwork([
            .failure(URLError(.notConnectedToInternet)), .status(401, "secret-error-body"),
            .status(200, "invalid-json-response"),
            .status(200, #"{"partialSuccess":{"rejectedSpans":"1","errorMessage":"private"}}"#),
        ])
        let exporter = network.exporter(batchSize: 2)
        for _ in 0..<8 { exporter.startSpan("failure.test")?.end() }
        let result = await exporter.shutdownAndWait()
        #expect(result.exportedSpans == 1)
        #expect(result.droppedSpans == 7)
        #expect(result.failedRequests == 3)
        #expect(network.requests.count == 4)
        #expect(try network.spans().count == 8)
    }

    @Test func batchingFlushAndShutdownDrainAllAcceptedSpans() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter(batchSize: 2)
        for i in 0..<5 { exporter.startSpan("batch.\(i)")?.end() }
        let result = await exporter.shutdownAndWait()
        #expect(result.exportedSpans == 5)
        #expect(result.droppedSpans == 0)
        #expect(network.requests.count == 3)
        #expect(try network.spans().count == 5)
        #expect(exporter.startSpan("after.shutdown") == nil)
        #expect(await exporter.flushAndWait() == result)
        #expect(network.requests.count == 3)
    }

    @Test func shutdownTimeoutCancelsOnlyExporterAndBoundsBuffer() async throws {
        let network = TelemetryFakeNetwork([.held])
        let exporter = network.exporter(batchSize: 1, bufferLimit: 2)
        for _ in 0..<10 { exporter.startSpan("held")?.end() }
        let start = Date()
        let result = await exporter.shutdownAndWait(timeout: 0.1)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(result.droppedSpans == 10)
        #expect(result.exportedSpans == 0)
        #expect(network.requests.count == 1)
        #expect(await exporter.flushAndWait() == result)
    }

    @Test func idleFlushTimerExportsSmallBatch() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter(flushInterval: 0.01)
        exporter.startSpan("scheduled")?.end()
        // A short deadline tests the one-shot batching timer, not live state.
        for _ in 0..<100 where network.requests.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(network.requests.count == 1)
        #expect((await exporter.shutdownAndWait()).exportedSpans == 1)
    }

    @Test func subprocessSpansCoverSyncAsyncNonzeroAndLaunchFailureWithoutArguments() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter()
        try await TraceContext.withSpan(exporter: exporter, name: "command.operation") {
            _ = try SubprocessRunner.run(arguments: ["sh", "-c", "printf private-terminal-text; exit 7"],
                                         cwd: FileManager.default.temporaryDirectory.path,
                                         environment: ProcessInfo.processInfo.environment, timeout: 2, tracingExporter: exporter)
            _ = try await SubprocessRunner.runAsync(arguments: ["sh", "-c", "printf private-prompt"],
                                                    cwd: FileManager.default.temporaryDirectory.path,
                                                    environment: ProcessInfo.processInfo.environment, timeout: 2, tracingExporter: exporter)
            do {
                _ = try SubprocessRunner.run(arguments: ["sh"], cwd: "/nonexistent-private-path",
                                             environment: [:], timeout: 2, tracingExporter: exporter)
                Issue.record("Expected launch failure")
            } catch {}
        }
        _ = await exporter.shutdownAndWait()
        let spans = try network.spans()
        let root = try #require(spans.first { $0["name"] as? String == "command.operation" })
        let commands = spans.filter { $0["name"] as? String == "subprocess.run" }
        #expect(commands.count == 3)
        #expect(attributes(commands[0])["process.exit.code"] == "7")
        #expect(attributes(commands[1])["process.exit.code"] == "0")
        #expect(attributes(commands[2])["error.type"] == "launch_failed")
        for span in commands {
            #expect(span["parentSpanId"] as? String == root["spanId"] as? String)
            #expect(span["traceId"] as? String == root["traceId"] as? String)
            #expect(attributes(span)["process.executable.name"] == "sh")
        }
        let body = String(data: try #require(network.requests.first?.httpBody), encoding: .utf8)!
        #expect(!body.contains("private"))
    }

    @Test func subprocessTimeoutAndCancellationEndSpansWithSafeErrors() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter()
        do {
            _ = try await SubprocessRunner.runAsync(arguments: ["sh", "-c", "exec sleep 5"],
                                                    cwd: FileManager.default.temporaryDirectory.path,
                                                    environment: ["PATH": "/usr/bin:/bin"], timeout: 0.05,
                                                    tracingExporter: exporter)
            Issue.record("Expected timeout")
        } catch {}
        let task = Task {
            try await SubprocessRunner.runAsync(arguments: ["sh", "-c", "exec sleep 5"],
                                               cwd: FileManager.default.temporaryDirectory.path,
                                               environment: ["PATH": "/usr/bin:/bin"], timeout: 5,
                                               tracingExporter: exporter)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch {}
        _ = await exporter.shutdownAndWait()
        let spans = try network.spans()
        #expect(spans.count == 2)
        #expect(Set(spans.compactMap { attributes($0)["error.type"] }) == ["timeout", "cancelled"])
        #expect(spans.allSatisfy { ($0["status"] as? [String: Int])?["code"] == 2 })
    }

    @Test func performanceBridgePreservesContextLifecycleAndLocalSupervisorPolicy() async throws {
        let network = TelemetryFakeNetwork()
        let exporter = network.exporter()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceEventStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
        let telemetry = PerformanceTelemetry(store: store, axiomExporter: exporter)
        await TraceContext.withSpan(exporter: exporter, name: "app.launch") {
            let id = telemetry.beginSpan("selected_context.resolve", detail: "secret-command --token private")
            telemetry.endSpan(id)
            telemetry.recordDuration("terminal.ready_wait", durationMS: 50, detail: "private-terminal-text")
            telemetry.recordDuration("supervisor.tick", durationMS: 200)
            telemetry.recordDurationLocalIfSlow("local.only", durationMS: 1000)
            telemetry.beginSessionSwitch(from: nil, to: "test-session", visibleSessionCount: 2)
            telemetry.noteSessionTerminalReady(sessionID: "test-session")
            telemetry.noteSessionFirstOutput(sessionID: "test-session")
        }
        telemetry.flushPendingEventsAndWait()
        _ = await exporter.shutdownAndWait()
        let spans = try network.spans()
        let launch = try #require(spans.first { $0["name"] as? String == "app.launch" })
        let context = try #require(spans.first { $0["name"] as? String == "selected_context.resolve" })
        #expect(context["parentSpanId"] as? String == launch["spanId"] as? String)
        let selection = try #require(spans.first { $0["name"] as? String == "session.switch" })
        let ready = try #require(spans.first { $0["name"] as? String == "session_switch.total" })
        #expect(ready["traceId"] as? String == selection["traceId"] as? String)
        #expect(ready["parentSpanId"] as? String == selection["spanId"] as? String)
        #expect(!spans.contains { ($0["name"] as? String)?.hasPrefix("supervisor.") == true })
        #expect(!spans.contains { $0["name"] as? String == "local.only" })
        let local = store.loadEvents(since: Date().addingTimeInterval(-60))
        #expect(local.contains { $0.name == "supervisor.tick" })
        #expect(local.contains { $0.detail?.contains("secret-command") == true })
        let body = String(data: try #require(network.requests.first?.httpBody), encoding: .utf8)!
        #expect(!body.contains("private"))
        #expect(!body.contains("secret-command"))
    }
}
