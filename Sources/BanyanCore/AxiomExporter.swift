import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TelemetryEvent: Sendable {
    public let name: String
    public let category: String
    public let durationMS: Double?
    public let attributes: [String: String]
    public let timestamp: Date

    public init(name: String, category: String, durationMS: Double? = nil,
                attributes: [String: String] = [:], timestamp: Date = Date()) {
        self.name = name
        self.category = category
        self.durationMS = durationMS
        self.attributes = attributes
        self.timestamp = timestamp
    }
}

/// Bounded, best-effort OTLP/HTTP JSON exporter. All mutable state is owned by
/// `queue`; exporter traffic deliberately bypasses TracedHTTP. Flush and shutdown
/// wait for responses, rather than merely scheduling URLSession tasks.
public final class AxiomExporter: @unchecked Sendable {
    public struct ExportResult: Sendable, Equatable {
        public var exportedSpans = 0
        public var droppedSpans = 0
        public var failedRequests = 0
    }

    private let config: TelemetryConfig
    private let session: URLSession?
    private let ownsSession: Bool
    private let appVersion: String
    private let queue = DispatchQueue(label: "app.banyan.axiom-exporter", qos: .utility)
    private let batchSize: Int
    private let bufferLimit: Int
    private let flushInterval: TimeInterval
    private var buffer: [CompletedSpan] = []
    private var scheduledFlush: DispatchWorkItem?
    private var request: URLSessionDataTask?
    private var requestID: UUID?
    private var inFlightCount = 0
    private var accepting = true
    private var result = ExportResult()
    private var waiters: [@Sendable (ExportResult) -> Void] = []

    /// The app uses this factory so disabled/no-token startup constructs neither
    /// an exporter nor a URLSession. Public init remains compatible with callers.
    public static func configured(config: TelemetryConfig, appVersion: String = "unknown") -> AxiomExporter? {
        guard config.isActive else { return nil }
        return AxiomExporter(config: config, appVersion: appVersion)
    }

    public init(config: TelemetryConfig, appVersion: String = "unknown",
                session: URLSession? = nil, batchSize: Int = 100,
                bufferLimit: Int = 1_000, flushInterval: TimeInterval = 30) {
        self.config = config
        self.ownsSession = config.isActive && session == nil
        self.appVersion = appVersion
        self.batchSize = max(1, batchSize)
        self.bufferLimit = max(1, bufferLimit)
        self.flushInterval = max(0.01, flushInterval)
        self.session = config.isActive
            ? session ?? URLSession(configuration: .ephemeral, delegate: NoExportRedirects(), delegateQueue: nil)
            : nil
    }

    deinit {
        scheduledFlush?.cancel()
        request?.cancel()
        if ownsSession { session?.invalidateAndCancel() }
    }

    public func startSpan(_ name: String, kind: Int = 1,
                          parent: SpanContext? = TraceContext.current,
                          attributes: [String: String] = [:]) -> TelemetrySpan? {
        guard config.isActive, queue.sync(execute: { accepting }) else { return nil }
        return TelemetrySpan(exporter: self, name: name, kind: kind, parent: parent, attributes: attributes)
    }

    public func send(_ event: TelemetryEvent) {
        let parent = TraceContext.current
        let duration = event.durationMS ?? 0
        enqueue(CompletedSpan(
            name: event.name, kind: 1, context: SpanContext(parent: parent), parent: parent,
            start: event.timestamp.addingTimeInterval(-(duration.isFinite ? max(0, duration) : 0) / 1000),
            durationMS: duration,
            attributes: event.attributes.merging(["category": event.category]) { _, new in new },
            isError: event.attributes["error.type"] != nil
        ))
    }

    func enqueue(_ span: CompletedSpan) {
        guard config.isActive else { return }
        queue.async { [self] in
            guard accepting else { return }
            guard buffer.count < bufferLimit else {
                result.droppedSpans += 1
                return
            }
            buffer.append(span)
            if buffer.count >= batchSize {
                flushLocked()
            } else if scheduledFlush == nil {
                // No repeating wakeups while idle. This timer is only for a
                // nonempty buffer, independent of UI/runtime state observation.
                let work = DispatchWorkItem { [weak self] in self?.flushLocked() }
                scheduledFlush = work
                queue.asyncAfter(deadline: .now() + flushInterval, execute: work)
            }
        }
    }

    public func flush(completion: @escaping @Sendable (ExportResult) -> Void = { _ in }) {
        queue.async { [self] in
            waiters.append(completion)
            flushLocked()
        }
    }

    public func flushAndWait() async -> ExportResult {
        await withCheckedContinuation { continuation in
            flush { continuation.resume(returning: $0) }
        }
    }

    /// Stops accepting new spans and drains queued/in-flight work. Timeout
    /// cancels only this exporter's task; late callbacks cannot finish twice.
    public func shutdown(timeout: TimeInterval = 3,
                         completion: @escaping @Sendable (ExportResult) -> Void) {
        queue.async { [self] in
            accepting = false
            waiters.append(completion)
            flushLocked()
            guard !waiters.isEmpty else { return }
            queue.asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                guard let self, !self.waiters.isEmpty else { return }
                self.result.droppedSpans += self.buffer.count + self.inFlightCount
                self.buffer.removeAll()
                self.inFlightCount = 0
                self.requestID = nil
                self.request?.cancel()
                self.request = nil
                self.finishIfIdleLocked()
            }
        }
    }

    public func shutdownAndWait(timeout: TimeInterval = 3) async -> ExportResult {
        await withCheckedContinuation { continuation in
            shutdown(timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    /// Termination notifications cannot await. The queue and URLSession callbacks
    /// never use the main thread, so a small bounded wait is safe here.
    public func shutdownBlocking(timeout: TimeInterval = 3) {
        let done = DispatchSemaphore(value: 0)
        shutdown(timeout: timeout) { _ in done.signal() }
        _ = done.wait(timeout: .now() + max(0, timeout) + 0.1)
    }

    private func flushLocked() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard request == nil else { return }
        guard !buffer.isEmpty, let session, let token = config.axiomAPIToken else {
            finishIfIdleLocked()
            return
        }
        let spans = Array(buffer.prefix(batchSize))
        buffer.removeFirst(spans.count)
        var http = URLRequest(url: URL(string: "https://api.axiom.co/v1/traces")!)
        http.httpMethod = "POST"
        http.timeoutInterval = 10
        http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        http.setValue(config.axiomDataset, forHTTPHeaderField: "X-Axiom-Dataset")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgID = config.axiomOrgID { http.setValue(orgID, forHTTPHeaderField: "X-Axiom-Org-ID") }
        let payload: [String: Any] = ["resourceSpans": [[
            "resource": ["attributes": CompletedSpan.keyValues([
                "service.name": "banyan", "service.version": appVersion,
            ])],
            "scopeSpans": [["scope": ["name": "app.banyan.tracing"], "spans": spans.map(\.json)]],
        ]]]
        do {
            http.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            result.droppedSpans += spans.count
            result.failedRequests += 1
            flushLocked()
            return
        }
        let id = UUID()
        requestID = id
        inFlightCount = spans.count
        let task = session.dataTask(with: http) { [self] data, response, error in
            self.queue.async {
                guard self.requestID == id else { return }
                self.requestID = nil
                self.request = nil
                self.inFlightCount = 0
                let status = (response as? HTTPURLResponse)?.statusCode
                let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                let validBody = (data?.isEmpty ?? true) || body != nil
                if error == nil, status == 200, validBody, (data?.count ?? 0) <= 4 * 1024 * 1024 {
                    // Partial success must never be retried. Do not print the
                    // server's free-form error message (it may echo input).
                    let partial = body?["partialSuccess"] as? [String: Any]
                    let rejected = min(spans.count, max(0, Int(String(describing: partial?["rejectedSpans"] ?? 0)) ?? 0))
                    self.result.exportedSpans += spans.count - rejected
                    self.result.droppedSpans += rejected
                } else {
                    // Best effort: drop failures rather than retain unbounded
                    // telemetry during an outage or retry permanent auth errors.
                    self.result.failedRequests += 1
                    self.result.droppedSpans += spans.count
                    NSLog("Banyan telemetry: OTLP export failed (HTTP %d); dropped %d spans", status ?? 0, spans.count)
                }
                if self.buffer.count >= self.batchSize || !self.waiters.isEmpty {
                    self.flushLocked()
                } else {
                    // Small batches keep their one-shot deadline. A fast prior
                    // response must not turn batching into one request per span.
                    self.finishIfIdleLocked()
                }
            }
        }
        request = task
        task.resume()
    }

    private func finishIfIdleLocked() {
        guard request == nil, buffer.isEmpty else { return }
        let completions = waiters
        waiters.removeAll()
        let snapshot = result
        guard !completions.isEmpty else { return }
        // User callbacks may call back into the exporter; never run them while
        // owning its serial queue.
        DispatchQueue.global(qos: .utility).async {
            for completion in completions { completion(snapshot) }
        }
    }
}

private final class NoExportRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension AxiomExporter {
    /// Compatibility for CLI clients' existing timing events. CLI calls are
    /// internal API operations, never fabricated HTTP requests/status codes.
    public func sendHTTPRequest(service: String, method: String, url: String,
                                statusCode: Int, durationMS: Double, error: String? = nil) {
        var attrs = ["service": service]
        if method != "CLI" {
            attrs["http.request.method"] = method
            attrs["url.full"] = TelemetryPrivacy.url(URL(string: url))
            attrs["http.response.status_code"] = String(statusCode)
        }
        if error != nil { attrs["error.type"] = "operation_failed" }
        send(TelemetryEvent(name: method == "CLI" ? "api.cli" : "http.request",
                            category: "api", durationMS: durationMS, attributes: attrs))
    }

    public func sendPerformanceEvent(_ event: PerformanceEvent, parent: SpanContext? = nil) {
        // Details may include paths, commands and terminal content. Keep them in
        // SQLite only. IDs are correlation metadata, never user-authored text.
        var attrs = ["category": "performance"]
        if let id = event.sessionID, UUID(uuidString: id) != nil { attrs["session_id"] = id }
        if let id = event.correlationID, UUID(uuidString: id) != nil { attrs["correlation_id"] = id }
        let duration = event.durationMS.isFinite ? max(0, event.durationMS) : 0
        enqueue(CompletedSpan(
            name: event.name, kind: 1, context: SpanContext(parent: parent), parent: parent,
            start: event.createdAt.addingTimeInterval(-duration / 1000), durationMS: duration,
            attributes: attrs, isError: false
        ))
    }

    public func sendAppLifecycle(_ event: String, attributes: [String: String] = [:]) {
        send(TelemetryEvent(name: event, category: "lifecycle", attributes: attributes))
    }
}
