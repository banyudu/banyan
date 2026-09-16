import BanyanCore
import AppKit
import Foundation
import Network

final class ControlServer {
    private weak var store: SessionStore?
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 7842
    private let token: String
    private let queue = DispatchQueue(label: "app.banyan.control-server")
    private var bindAttempts = 0
    /// ~30s of retries at 1s each, enough to outlast a previous instance releasing
    /// the port on a quick restart, without looping forever.
    private let maxBindAttempts = 30
    /// `/events` requests parked until a session changes status. Main-actor only.
    private var eventWaiters: [EventWaiter] = []
    /// How long a parked `/events` request is held before it answers empty. Long
    /// enough that an idle bridge makes a couple of requests a minute rather than
    /// a poll loop, short enough to stay inside an ordinary client timeout.
    private static let eventHoldSeconds: TimeInterval = 25
    /// Past this many parked requests, `/events` answers immediately instead of
    /// accumulating connections a misbehaving client will never read.
    private static let maxEventWaiters = 32

    private struct Response {
        let status: Int
        let data: [String: Any]?
        let error: ControlErrorBody?

        static func ok(_ data: [String: Any]) -> Response {
            Response(status: 200, data: data, error: nil)
        }

        static func failure(_ status: Int, _ code: String, _ message: String) -> Response {
            Response(status: status, data: nil, error: ControlErrorBody(code: code, message: message))
        }
    }

    private struct EventWaiter {
        let id: UUID
        let since: Int?
        let respond: (Response) -> Void
    }

    init(store: SessionStore, host: HostRuntimeContext) {
        self.store = store
        self.token = (try? ControlToken.loadOrCreate(
            environment: host.environment,
            homeDirectory: host.homeDirectory
        )) ?? ""
    }

    @MainActor
    func start() {
        // Edge-triggered: the store already raises a callback on every real status
        // change, so a parked request is woken by the transition itself rather than
        // by anything on a schedule.
        store?.onSessionEvent = { [weak self] _ in
            self?.deliverParkedEvents()
        }
        startListener()
    }

    private func startListener() {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            NSLog("Banyan control server could not create listener on port \(port): \(error.localizedDescription)")
            scheduleBindRetry()
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        // Previously the bind failure (e.g. the port still held by a restarting
        // instance) surfaced only through this state — with no handler set, the
        // listener silently never bound and the control server was dead until the
        // next launch. Observe it and retry with a fresh listener.
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.bindAttempts > 0 {
                    NSLog("Banyan control server bound to port \(self.port) after \(self.bindAttempts) retr\(self.bindAttempts == 1 ? "y" : "ies")")
                }
                self.bindAttempts = 0
            case .waiting(let error):
                // Typically EADDRINUSE while a prior instance releases the port.
                // Network.framework auto-retries, but recreate on a delay too so we
                // recover deterministically even if it stops.
                NSLog("Banyan control server waiting to bind port \(self.port): \(error.localizedDescription)")
                self.retire(listener, thenRetry: true)
            case .failed(let error):
                NSLog("Banyan control server listener failed: \(error.localizedDescription)")
                self.retire(listener, thenRetry: true)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func retire(_ oldListener: NWListener, thenRetry: Bool) {
        oldListener.stateUpdateHandler = nil
        oldListener.cancel()
        if listener === oldListener {
            listener = nil
        }
        if thenRetry {
            scheduleBindRetry()
        }
    }

    private func scheduleBindRetry() {
        guard bindAttempts < maxBindAttempts else {
            NSLog("Banyan control server gave up binding port \(port) after \(bindAttempts) attempts")
            return
        }
        bindAttempts += 1
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.listener == nil else { return }
            self.startListener()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "app.banyan.control-connection"))
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.send(connection, status: 500, data: nil, error: ControlErrorBody(code: "connection_error", message: error.localizedDescription))
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if ControlProtocol.isCompleteHTTPMessage(nextBuffer) {
                Task { @MainActor in
                    // The reply may be produced now, after tmux work, or only once a
                    // session changes status, so the connection is handed to the
                    // route rather than answered on return from it.
                    self.route(nextBuffer) { [weak self] response in
                        self?.send(connection, status: response.status, data: response.data, error: response.error)
                    }
                }
                return
            }

            if isComplete {
                self.send(connection, status: 400, data: nil, error: ControlErrorBody(code: "empty_request", message: "empty request"))
                return
            }

            self.receiveRequest(connection, buffer: nextBuffer)
        }
    }

    @MainActor
    private func route(_ data: Data, respond: @escaping @MainActor (Response) -> Void) {
        guard let request = HTTPControlRequest(data: data) else {
            return respond(.failure(400, "invalid_http", "invalid HTTP request"))
        }

        guard let store else {
            return respond(.failure(500, "store_unavailable", "session store is unavailable"))
        }
        guard token.isEmpty || request.headers[ControlToken.headerName.lowercased()] == token else {
            return respond(.failure(401, "unauthorized", "invalid Banyan control token"))
        }

        do {
            guard let route = ControlRoute.resolve(method: request.method, path: request.path) else {
                return respond(.failure(404, "unknown_route", "unknown route"))
            }

            switch route {
            case .list:
                return respond(.ok(["sessions": store.sessions.map(summary)]))

            case .select:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                store.select(id: id)
                return respond(.ok(["session": summary(session)]))

            case .windowState:
                return respond(.ok(windowState()))

            case .tick:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try store.tick(id: body.id)
                let visibleSessions = body.id.flatMap { id in
                    store.sessions.first(where: { $0.id == id }).map { [$0] }
                } ?? store.sessions
                return respond(.ok(["sessions": visibleSessions.map(summary)]))

            case .spawn:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                let tone = body.tone.flatMap(SessionTone.init(rawValue:)) ?? .blue
                let parentSessionID = try store.resolvedParentSessionIDForSpawn(body.parent)
                // Default to a background spawn (do not steal the user's focus) unless
                // focus was explicitly requested, or nothing is currently selected.
                let shouldSelect = body.focus.flatMap(Bool.init) ?? (store.selectedSessionID == nil)
                let session = store.spawn(
                    id: body.id,
                    title: body.title,
                    titleURL: body.titleURL,
                    cwd: body.cwd,
                    command: body.command,
                    parentSessionID: parentSessionID,
                    tone: tone,
                    select: shouldSelect
                )
                return respond(.ok(["session": summary(session)]))

            case .mark:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                let status = try body.status.map(parseStatus)
                let tone = try body.tone.map(parseTone)
                try store.mark(id: id, status: status, tone: tone, title: body.title, titleURL: body.titleURL)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return respond(.ok(["session": summary(session)]))

            case .close:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                try store.close(id: body.id!)
                return respond(.ok(["ok": true]))

            case .respawn:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                try store.respawn(id: id)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return respond(.ok(["session": summary(session)]))

            case .restart:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                try store.restart(id: id)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return respond(.ok(["session": summary(session)]))

            case .suspend, .resume:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                try store.setSuspended(id: id, suspended: route == .suspend)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return respond(.ok(["session": summary(session)]))

            case .remove:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                try store.remove(id: body.id!)
                return respond(.ok(["ok": true]))

            case .screenshot:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let url = try VisualSnapshotter.captureMainWindow(to: body.path!)
                return respond(.ok(["path": url.path]))

            case .output:
                let body = try payload(for: request)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                return readOutput(store: store, body: body, respond: respond)

            case .input:
                let body = try payload(for: request)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                return sendInput(store: store, body: body, respond: respond)

            case .answer:
                let body = try payload(for: request)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                return sendAnswer(store: store, body: body, respond: respond)

            case .events:
                let body = try payload(for: request)
                try validateVersion(body.apiVersion)
                return waitForEvents(store: store, since: body.since?.value, respond: respond)
            }
        } catch let error as ControlError {
            return respond(.failure(error.httpStatus, error.code, error.localizedDescription))
        } catch let error as ControlValidationError {
            return respond(.failure(400, "missing_required_field", error.localizedDescription))
        } catch is DecodingError {
            return respond(.failure(400, "malformed_json", "malformed JSON request body"))
        } catch {
            return respond(.failure(400, "bad_request", error.localizedDescription))
        }
    }

    /// Decodes a request body, then lets any query string override it.
    ///
    /// `/output` and `/events` are documented as GETs with parameters, and a GET
    /// carries no body — so the query string has to reach the same payload type
    /// the POST routes decode.
    private func payload(for request: HTTPControlRequest) throws -> ControlPayload {
        let query = ControlRoute.queryItems(in: request.path)
        guard !query.isEmpty else {
            return try request.decode(ControlPayload.self)
        }
        var merged = try JSONSerialization.jsonObject(
            with: request.body.isEmpty ? Data("{}".utf8) : request.body
        ) as? [String: Any] ?? [:]
        for (name, value) in query {
            merged[name] = value
        }
        let data = try JSONSerialization.data(withJSONObject: merged)
        return try JSONDecoder().decode(ControlPayload.self, from: data)
    }

    // MARK: - Pane routes

    @MainActor
    private func readOutput(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        let lines = body.lines.map { max(1, min(2_000, $0.value)) }
        Task { @MainActor in
            do {
                let reading = try await store.readPaneOutput(id: id, lines: lines)
                respond(.ok(self.outputBody(id: id, store: store, reading: reading)))
            } catch {
                respond(self.failure(for: error))
            }
        }
    }

    @MainActor
    private func sendInput(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        var keys: [TmuxKey] = []
        for name in body.keys ?? [] {
            guard let key = TmuxKey(name: name) else {
                return respond(.failure(
                    400,
                    "unknown_key",
                    "unknown key '\(name)'; allowed: \(TmuxKey.allCases.map(\.rawValue).joined(separator: ", "))"
                ))
            }
            keys.append(key)
        }
        let text = body.text
        let submit = body.submit?.value ?? false
        Task { @MainActor in
            do {
                let receipt = try await store.injectInput(id: id, keys: keys, text: text, submit: submit)
                respond(.ok([
                    "id": id,
                    "paneID": receipt.paneID,
                    "keys": receipt.keys.map(\.rawValue),
                    "text": receipt.text ?? ""
                ]))
            } catch {
                respond(self.failure(for: error))
            }
        }
    }

    @MainActor
    private func sendAnswer(
        store: SessionStore,
        body: ControlPayload,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let id = body.id!
        var choice: AgentPromptChoice?
        if let raw = body.choice, !raw.isEmpty {
            guard let parsed = AgentPromptChoice(name: raw) else {
                return respond(.failure(
                    400,
                    "unknown_choice",
                    "unknown choice '\(raw)'; allowed: \(AgentPromptChoice.allCases.map(\.rawValue).joined(separator: ", "))"
                ))
            }
            choice = parsed
        }
        let request = AgentAnswerRequest(
            option: body.option?.value,
            choice: choice,
            confirm: body.confirm?.value ?? false,
            footprint: body.footprint!
        )
        Task { @MainActor in
            do {
                let receipt = try await store.answerPrompt(id: id, request: request)
                switch receipt.decision {
                case .send(let keys, let option):
                    var payload = self.outputBody(id: id, store: store, reading: receipt.reading)
                    payload["sent"] = true
                    payload["keys"] = keys.map(\.rawValue)
                    payload["option"] = option.index
                    payload["optionLabel"] = option.label
                    respond(.ok(payload))
                case .reject(let rejection):
                    // A refusal still carries the current reading, so a delivery
                    // target can redraw what the session actually shows now instead
                    // of asking again.
                    respond(Response(
                        status: rejection.httpStatus,
                        data: self.outputBody(id: id, store: store, reading: receipt.reading),
                        error: ControlErrorBody(code: rejection.rawValue, message: rejection.message)
                    ))
                }
            } catch {
                respond(self.failure(for: error))
            }
        }
    }

    /// Answers with any transitions since `since`, or parks the request until one
    /// lands. Parking beats a client poll loop: nothing here runs on a schedule,
    /// and the one timer involved is a single-shot release for this request.
    @MainActor
    private func waitForEvents(
        store: SessionStore,
        since: Int?,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let batch = store.sessionEvents(since: since)
        guard since != nil, batch.events.isEmpty, eventWaiters.count < Self.maxEventWaiters else {
            return respond(.ok(eventsBody(batch)))
        }

        let id = UUID()
        eventWaiters.append(EventWaiter(id: id, since: since, respond: respond))
        queue.asyncAfter(deadline: .now() + Self.eventHoldSeconds) { [weak self] in
            Task { @MainActor in
                self?.releaseWaiter(id: id)
            }
        }
    }

    @MainActor
    private func deliverParkedEvents() {
        guard !eventWaiters.isEmpty, let store else { return }
        let waiting = eventWaiters
        eventWaiters = []
        for waiter in waiting {
            waiter.respond(.ok(eventsBody(store.sessionEvents(since: waiter.since))))
        }
    }

    @MainActor
    private func releaseWaiter(id: UUID) {
        guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = eventWaiters.remove(at: index)
        let batch = store?.sessionEvents(since: waiter.since)
            ?? SessionEventBatch(events: [], cursor: waiter.since ?? 0, truncated: false)
        waiter.respond(.ok(eventsBody(batch)))
    }

    private func eventsBody(_ batch: SessionEventBatch) -> [String: Any] {
        [
            "cursor": batch.cursor,
            "truncated": batch.truncated,
            "events": batch.events.map { event in
                [
                    "cursor": event.cursor,
                    "id": event.sessionID,
                    "status": event.status.rawValue,
                    "statusEmoji": event.status.emoji,
                    "previousStatus": event.previousStatus?.rawValue ?? "",
                    "at": ISO8601DateFormatter().string(from: event.at)
                ]
            }
        ]
    }

    @MainActor
    private func outputBody(id: String, store: SessionStore, reading: SessionPaneReading) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "paneID": reading.paneID,
            "status": reading.status.rawValue,
            "statusEmoji": reading.status.emoji,
            // A parked session is reported, not observed: its status is whatever was
            // last seen and it carries no prompt, so say so rather than let a caller
            // read the frozen status as a live one.
            "isSuspended": reading.isSuspended,
            "visibleText": reading.visibleText
        ]
        if let session = store.sessions.first(where: { $0.id == id }) {
            payload["session"] = summary(session)
        }
        if let prompt = reading.prompt {
            payload["prompt"] = [
                "question": prompt.question,
                "context": prompt.context,
                "selectedIndex": prompt.selectedIndex,
                "footprint": prompt.footprint,
                "options": prompt.options.map { option in
                    [
                        "index": option.index,
                        "label": option.label,
                        "acceptsNumberKey": option.acceptsNumberKey
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return payload
    }

    private func failure(for error: Error) -> Response {
        if let error = error as? ControlError {
            return .failure(error.httpStatus, error.code, error.localizedDescription)
        }
        return .failure(400, "bad_request", error.localizedDescription)
    }

    private func validateVersion(_ apiVersion: String?) throws {
        let version = apiVersion ?? ControlProtocol.version
        guard version == ControlProtocol.version else {
            throw ControlError.badRequest("unsupported apiVersion '\(version)'")
        }
    }

    private func parseStatus(_ raw: String) throws -> SessionStatus {
        guard let status = SessionStatus(rawValue: raw) else {
            throw ControlError.badRequest("unknown status '\(raw)'")
        }
        return status
    }

    private func parseTone(_ raw: String) throws -> SessionTone {
        guard let tone = SessionTone(rawValue: raw) else {
            throw ControlError.badRequest("unknown tone '\(raw)'")
        }
        return tone
    }

    @MainActor
    private func windowState() -> [String: Any] {
        let window = NSApp.windows.first { $0.isVisible } ?? NSApp.mainWindow
        var state: [String: Any] = [
            "title": window?.title ?? "",
            "titleVisibility": window?.titleVisibility == .hidden ? "hidden" : "visible"
        ]
        state["selectedSessionID"] = store?.selectedSessionID ?? ""
        if let context = store?.selectedContextInfo {
            let selectedContext: [String: String] = [
                "sessionID": context.sessionID,
                "linearIssueID": context.linearIssueID ?? "",
                "linearIssueTitle": context.linearIssueTitle ?? "",
                "linearIssueURL": context.linearIssueURL ?? "",
                "pullRequestNumber": context.pullRequestNumber.map(String.init) ?? "",
                "pullRequestTitle": context.pullRequestTitle ?? "",
                "pullRequestURL": context.pullRequestURL ?? ""
            ]
            state["selectedContext"] = selectedContext
        }
        if let window {
            state["windowWidth"] = window.frame.width
            let actionFrames = [
                viewFrame(window: window, identifier: AccessibilityID.toolbarPullRequestLink),
                viewFrame(window: window, identifier: AccessibilityID.toolbarAddSession),
                viewFrame(window: window, identifier: AccessibilityID.toolbarPreferences)
            ].compactMap(\.self)
            if let contextFrame = viewFrame(window: window, identifier: AccessibilityID.toolbarContext) {
                state["toolbarContextFound"] = true
                state["toolbarContextMinX"] = contextFrame.minX
                state["toolbarContextMaxX"] = contextFrame.maxX
                state["toolbarContextWidth"] = contextFrame.width
            } else {
                state["toolbarContextFound"] = false
            }
            if !actionFrames.isEmpty {
                let actionsFrame = actionFrames.dropFirst().reduce(actionFrames[0]) { $0.union($1) }
                state["toolbarActionsFound"] = true
                state["toolbarActionsMinX"] = actionsFrame.minX
                state["toolbarActionsMaxX"] = actionsFrame.maxX
                state["toolbarActionsWidth"] = actionsFrame.width
            } else {
                state["toolbarActionsFound"] = false
            }
        }
        return state
    }

    @MainActor
    private func viewFrame(window: NSWindow, identifier: String) -> NSRect? {
        let roots = [window.contentView, window.contentView?.superview].compactMap(\.self)
        for root in roots {
            if let view = firstSubview(in: root, identifier: identifier) {
                return view.convert(view.bounds, to: nil)
            }
        }
        return nil
    }

    private func firstSubview(in view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier || view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = firstSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func summary(_ session: BanyanSession) -> [String: Any] {
        [
            "id": session.id,
            "tmuxSessionName": session.tmuxSessionName,
            "title": session.title,
            "titleURL": session.titleURL ?? "",
            "displayTitle": session.displayTitle,
            "reportedTitle": session.reportedTitle ?? "",
            "generatedTitle": session.generatedTitle ?? "",
            "agentProvider": session.agentProvider?.rawValue ?? "",
            "cwd": session.cwd,
            "command": session.command,
            "status": session.status.rawValue,
            "statusEmoji": session.status.emoji,
            "tone": session.tone.rawValue,
            "parent": session.parentSessionID ?? "",
            "isRestored": session.isRestored,
            "isProcessStarted": session.isProcessStarted,
            "isSuspended": session.isSuspended,
            "projectGroupID": session.projectGroupID,
            "projectGroupTitle": session.projectGroupTitle,
            "displayContextDegraded": session.displayContextDegraded,
            "createdAt": ISO8601DateFormatter().string(from: session.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt)
        ]
    }

    private func send(_ connection: NWConnection, status: Int, data: [String: Any]?, error: ControlErrorBody?) {
        var payload: [String: Any] = [
            "apiVersion": ControlProtocol.version,
            "ok": error == nil
        ]
        if let data {
            payload["data"] = data
        }
        if let error {
            payload["error"] = [
                "code": error.code,
                "message": error.message
            ]
        }
        let body = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let reason = status == 200 ? "OK" : "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
