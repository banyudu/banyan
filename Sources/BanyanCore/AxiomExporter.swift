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

    public init(
        name: String,
        category: String,
        durationMS: Double? = nil,
        attributes: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.name = name
        self.category = category
        self.durationMS = durationMS
        self.attributes = attributes
        self.timestamp = timestamp
    }
}

public final class AxiomExporter: @unchecked Sendable {
    private let config: TelemetryConfig
    private let queue = DispatchQueue(label: "app.banyan.axiom-exporter", qos: .utility)
    private var buffer: [[String: Any]] = []
    private var flushTimer: DispatchSourceTimer?
    private let hostname: String
    private let appVersion: String

    private static let flushInterval: TimeInterval = 30
    private static let maxBufferSize = 100
    private static let ingestPath = "/v1/datasets"

    public init(config: TelemetryConfig, appVersion: String = "unknown") {
        self.config = config
        self.hostname = ProcessInfo.processInfo.hostName
        self.appVersion = appVersion
        guard config.isActive else { return }
        startFlushTimer()
    }

    deinit {
        flushTimer?.cancel()
        flush()
    }

    public func send(_ event: TelemetryEvent) {
        guard config.isActive else { return }
        var payload: [String: Any] = [
            "_time": Self.formatDate(event.timestamp),
            "event": event.name,
            "category": event.category,
            "host": hostname,
            "app_version": appVersion,
        ]
        if let durationMS = event.durationMS {
            payload["duration_ms"] = durationMS
        }
        for (key, value) in event.attributes {
            payload[key] = value
        }
        let payloadCopy = payload
        queue.async { [weak self, payloadCopy] in
            guard let self else { return }
            self.buffer.append(payloadCopy)
            if self.buffer.count >= Self.maxBufferSize {
                self.flushLocked()
            }
        }
    }

    public func flush() {
        queue.async { [weak self] in
            self?.flushLocked()
        }
    }

    private func flushLocked() {
        guard !buffer.isEmpty, config.isActive,
              let token = config.axiomAPIToken else { return }
        let events = buffer
        buffer = []

        guard let url = URL(string: "https://api.axiom.co\(Self.ingestPath)/\(config.axiomDataset)/ingest") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let orgID = config.axiomOrgID {
            request.setValue(orgID, forHTTPHeaderField: "X-Axiom-Org-ID")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: events)
        } catch {
            NSLog("Banyan telemetry: failed to serialize events: \(error.localizedDescription)")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                NSLog("Banyan telemetry: export failed: \(error.localizedDescription)")
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                NSLog("Banyan telemetry: Axiom returned HTTP \(http.statusCode)")
            }
        }
        task.resume()
    }

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.flushInterval,
            repeating: Self.flushInterval
        )
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        timer.resume()
        flushTimer = timer
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

// MARK: - Convenience helpers for common event types

extension AxiomExporter {
    public func sendHTTPRequest(
        service: String,
        method: String,
        url: String,
        statusCode: Int,
        durationMS: Double,
        error: String? = nil
    ) {
        var attrs: [String: String] = [
            "service": service,
            "http.method": method,
            "http.url": url,
            "http.status_code": String(statusCode),
        ]
        if let error { attrs["error"] = error }
        send(TelemetryEvent(
            name: "http.request",
            category: "api",
            durationMS: durationMS,
            attributes: attrs
        ))
    }

    public func sendSubprocess(
        command: String,
        exitCode: Int32,
        durationMS: Double,
        error: String? = nil
    ) {
        var attrs: [String: String] = [
            "command": command,
            "exit_code": String(exitCode),
        ]
        if let error { attrs["error"] = error }
        send(TelemetryEvent(
            name: "subprocess.run",
            category: "subprocess",
            durationMS: durationMS,
            attributes: attrs
        ))
    }

    public func sendPerformanceEvent(_ event: PerformanceEvent) {
        var attrs: [String: String] = [:]
        if let sessionID = event.sessionID { attrs["session_id"] = sessionID }
        if let correlationID = event.correlationID { attrs["correlation_id"] = correlationID }
        if let detail = event.detail { attrs["detail"] = detail }
        send(TelemetryEvent(
            name: event.name,
            category: "performance",
            durationMS: event.durationMS,
            attributes: attrs,
            timestamp: event.createdAt
        ))
    }

    public func sendAppLifecycle(_ event: String, attributes: [String: String] = [:]) {
        send(TelemetryEvent(
            name: event,
            category: "lifecycle",
            attributes: attributes
        ))
    }
}
