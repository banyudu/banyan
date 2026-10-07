import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// W3C trace context, also used by OTLP. IDs are nonzero random hex strings.
public struct SpanContext: Sendable, Equatable {
    public let traceID: String
    public let spanID: String

    init(parent: SpanContext? = nil) {
        traceID = parent?.traceID ?? Self.randomID()
        spanID = String(Self.randomID().prefix(16))
    }

    private static func randomID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public var traceparent: String { "00-\(traceID)-\(spanID)-01" }
}

public enum TraceContext {
    @TaskLocal public static var current: SpanContext?

    public static func withSpan<T>(
        exporter: AxiomExporter?, name: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        let span = exporter?.startSpan(name)
        do {
            let value = try await $current.withValue(span?.context ?? current, operation: operation)
            span?.end()
            return value
        } catch {
            span?.end(errorType: TelemetryPrivacy.errorType(error))
            throw error
        }
    }
}

public final class TelemetrySpan: @unchecked Sendable {
    public let context: SpanContext
    private let parent: SpanContext?
    private let name: String
    private let kind: Int
    private let start: Date
    private let clock = DispatchTime.now()
    private let attributes: [String: String]
    private let exporter: AxiomExporter
    private let lock = NSLock()
    private var ended = false

    init(exporter: AxiomExporter, name: String, kind: Int, parent: SpanContext?, attributes: [String: String]) {
        self.exporter = exporter
        self.name = name
        self.kind = kind
        self.parent = parent
        self.context = SpanContext(parent: parent)
        self.start = Date()
        self.attributes = attributes
    }

    /// Idempotent, including when cancellation and completion race.
    public func end(attributes: [String: String] = [:], errorType: String? = nil) {
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        lock.unlock()
        var combined = self.attributes.merging(attributes) { _, new in new }
        if let errorType { combined["error.type"] = errorType }
        exporter.enqueue(CompletedSpan(
            name: name, kind: kind, context: context, parent: parent,
            start: start, durationMS: PerformanceTelemetry.elapsedMS(since: clock),
            attributes: combined, isError: errorType != nil
        ))
    }
}

struct CompletedSpan: Sendable {
    let name: String
    let kind: Int
    let context: SpanContext
    let parent: SpanContext?
    let start: Date
    let durationMS: Double
    let attributes: [String: String]
    let isError: Bool

    var json: [String: Any] {
        let duration = durationMS.isFinite ? max(0, durationMS) : 0
        var result: [String: Any] = [
            "traceId": context.traceID, "spanId": context.spanID,
            "name": name, "kind": kind, "flags": 1,
            "startTimeUnixNano": Self.nanoseconds(start),
            "endTimeUnixNano": Self.nanoseconds(start.addingTimeInterval(duration / 1000)),
            "attributes": Self.keyValues(TelemetryPrivacy.attributes(attributes).merging(
                ["duration_ms": String(duration)]
            ) { _, new in new }),
            "status": ["code": isError ? 2 : 1],
        ]
        if let parent { result["parentSpanId"] = parent.spanID }
        return result
    }

    static func keyValues(_ values: [String: String]) -> [[String: Any]] {
        values.sorted { $0.key < $1.key }.map { key, value in
            let encoded: [String: Any]
            if ["http.response.status_code", "process.exit.code", "visible_session_count"].contains(key),
               let number = Int64(value) {
                encoded = ["intValue": String(number)]
            } else if key == "duration_ms", let number = Double(value), number.isFinite {
                encoded = ["doubleValue": number]
            } else {
                encoded = ["stringValue": value]
            }
            return ["key": key, "value": encoded]
        }
    }

    private static func nanoseconds(_ date: Date) -> String {
        String(UInt64(max(0, min(date.timeIntervalSince1970 * 1_000_000_000, Double(Int64.max)))))
    }
}

/// Only known structural fields leave the machine. Never export free-form
/// detail, stderr, request bodies, prompts, terminal output or command arguments.
enum TelemetryPrivacy {
    static func attributes(_ values: [String: String]) -> [String: String] {
        let allowed: Set<String> = [
            "category", "service", "http.request.method", "http.response.status_code",
            "url.full", "server.address", "process.executable.name", "process.exit.code",
            "error.type", "sidebar.mode", "sidebar.previous_mode", "correlation_id",
            "session_id", "visible_session_count", "smoke.marker",
        ]
        var safe = values.filter { allowed.contains($0.key) }.mapValues { String($0.prefix(256)) }
        if let value = safe["url.full"] { safe["url.full"] = url(URL(string: value)) }
        if let value = safe["process.executable.name"] { safe["process.executable.name"] = command(value) }
        for key in ["session_id", "correlation_id", "smoke.marker"] {
            if let value = safe[key], UUID(uuidString: value) == nil { safe.removeValue(forKey: key) }
        }
        return safe
    }

    static func command(_ command: String) -> String {
        // Arbitrary executable names can themselves contain secrets. Only report
        // known tool names; preserve neither paths nor the rest of the command.
        let name = URL(fileURLWithPath: command).lastPathComponent
        return ["gh", "git", "linear", "tmux", "zsh", "bash", "sh", "env", "codex", "claude"].contains(name)
            ? name : "other"
    }

    static func url(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme) else { return "redacted" }
        parts.user = nil
        parts.password = nil
        parts.query = nil
        parts.fragment = nil
        // Keep known API routes. Arbitrary paths (including signed asset URLs)
        // can contain credentials, private repository names or user content.
        parts.path = parts.host == "api.linear.app" && parts.path == "/graphql"
            ? "/graphql" : "/"
        return parts.string ?? "redacted"
    }

    static func errorType(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? URLError { return "url_error_\(error.code.rawValue)" }
        if let error = error as? SubprocessRunner.RunError {
            switch error {
            case .cancelled: return "cancelled"
            case .timedOut: return "timeout"
            case .launchFailed: return "launch_failed"
            }
        }
        return "operation_failed"
    }
}

/// Explicit wrappers avoid intercepting the exporter's own URLSession traffic.
public enum TracedHTTP {
    public static func data(
        for request: URLRequest, session: URLSession = .shared,
        exporter: AxiomExporter?, service: String
    ) async throws -> (Data, URLResponse) {
        try await perform(request: request, exporter: exporter, service: service) {
            try await session.data(for: $0)
        }
    }

    public static func download(
        for request: URLRequest, session: URLSession = .shared,
        exporter: AxiomExporter?, service: String
    ) async throws -> (URL, URLResponse) {
        try await perform(request: request, exporter: exporter, service: service) {
            try await session.download(for: $0)
        }
    }

    private static func perform<T>(
        request: URLRequest, exporter: AxiomExporter?, service: String,
        operation: (URLRequest) async throws -> (T, URLResponse)
    ) async throws -> (T, URLResponse) {
        let span = exporter?.startSpan("http.request", kind: 3, attributes: [
            "service": service, "http.request.method": request.httpMethod ?? "GET",
            "url.full": TelemetryPrivacy.url(request.url),
            "server.address": request.url?.host ?? "unknown",
        ])
        var propagated = request
        if let span { propagated.setValue(span.context.traceparent, forHTTPHeaderField: "traceparent") }
        do {
            let result = try await TraceContext.$current.withValue(span?.context ?? TraceContext.current) {
                try await operation(propagated)
            }
            let status = (result.1 as? HTTPURLResponse)?.statusCode
            span?.end(
                attributes: status.map { ["http.response.status_code": String($0)] } ?? [:],
                errorType: status.flatMap { $0 >= 400 ? "http_\($0)" : nil }
            )
            return result
        } catch {
            span?.end(errorType: TelemetryPrivacy.errorType(error))
            throw error
        }
    }
}
