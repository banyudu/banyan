import Foundation

public enum PuckDaemonWatchUpdate: Sendable {
    case snapshot([PuckSessionSummary])
    case event(sessionID: String, PuckSessionEvent)
}

/// One dashboard subscription owns presence for all its sessions. Transcript
/// attachments need no capability: simply viewing a session is not activity.
public protocol PuckDaemonObservation: Sendable {
    var updates: AsyncThrowingStream<PuckDaemonWatchUpdate, Error> { get }
    func reportPresence(active: Bool)
    func cancel()
}

extension PuckDaemonClient {
    public func watch() -> any PuckDaemonObservation { PuckSocketObservation(client: self) }
}

private final class PuckSocketObservation: PuckDaemonObservation, @unchecked Sendable {
    let updates: AsyncThrowingStream<PuckDaemonWatchUpdate, Error>
    private let state: PuckWatchConnectionState

    init(client: PuckDaemonClient) {
        let state = PuckWatchConnectionState()
        self.state = state
        updates = AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in state.cancel() }
            let thread = Thread {
                do {
                    let connection = try PuckDaemonConnection(socketPath: client.socketPath)
                    guard state.adopt(connection) else { return }
                    // Register away before claiming interactivity. Puck treats a
                    // fresh registration as activity; using notify temporarily
                    // avoids a false desk lease during a background reconnect.
                    let identity = ["name": "Banyan", "kind": "banyan", "capability": "notify"]
                    _ = try connection.request("session.watch", params: ["client": identity])
                    let presence = try connection.request("presence.away") as? [String: Any]
                    _ = try connection.request("session.watch", params: ["client": [
                        "name": "Banyan", "kind": "banyan", "capability": "interactive"
                    ]])
                    state.ready(window: (presence?["window_seconds"] as? NSNumber)?.doubleValue ?? 300)
                    // Watch first, then snapshot. Changes during this listing
                    // remain buffered on the subscribed socket.
                    continuation.yield(.snapshot(try client.list()))
                    while let message = try connection.nextNotification() {
                        guard let params = message["params"] as? [String: Any],
                              let data = params["data"] as? [String: Any],
                              let kind = data["event"] as? String else {
                            throw PuckDaemonError.invalidResponse("watch notification")
                        }
                        // Global presence and lag markers carry no session or
                        // durable cursor. They are not transcript entries.
                        if kind == "presence_changed" { continue }
                        if kind == "lagged" {
                            continuation.yield(.snapshot(try client.list()))
                            continue
                        }
                        guard let id = params["session"] as? String, !id.isEmpty else {
                            throw PuckDaemonError.invalidResponse("watch session")
                        }
                        let event = try PuckSessionEvent(params)
                        if kind == "turn_started" || PuckDaemonClient.summaryEventKinds.contains(kind) {
                            continuation.yield(.snapshot(try client.list()))
                        }
                        continuation.yield(.event(sessionID: id, event))
                    }
                    continuation.finish()
                } catch {
                    if state.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: error) }
                }
                state.cancel()
            }
            thread.name = "puck-watch"
            thread.start()
        }
    }

    func reportPresence(active: Bool) { state.reportPresence(active: active) }
    func cancel() { state.cancel() }
    deinit { state.cancel() }
}

/// The reader alone parses replies and events. A serial writer reports activity
/// without blocking the main actor or racing concurrent writes on that socket.
private final class PuckWatchConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "banyan.puck-presence")
    private var connection: PuckDaemonConnection?
    private var cancelled = false
    private var isReady = false
    private var lastActivity: Date?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func adopt(_ connection: PuckDaemonConnection) -> Bool {
        lock.withLock {
            guard !cancelled else { connection.disconnect(); return false }
            self.connection = connection
            return true
        }
    }

    func ready(window: TimeInterval) {
        lock.withLock {
            isReady = true
            let active = lastActivity.map { Date().timeIntervalSince($0) < window } ?? false
            if !active { lastActivity = nil }
            enqueuePresence(active: active)
        }
    }

    func reportPresence(active: Bool) {
        lock.withLock {
            lastActivity = active ? Date() : nil
            if isReady && !cancelled { enqueuePresence(active: active) }
        }
    }

    private func enqueuePresence(active: Bool) {
        writer.async { [self] in
            let connection = lock.withLock { cancelled ? nil : connection }
            do { try connection?.sendRequest(active ? "presence.active" : "presence.away") }
            catch { cancel() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            connection?.disconnect()
            connection = nil
        }
    }
}
