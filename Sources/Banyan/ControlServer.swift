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

    init(store: SessionStore) {
        self.store = store
        self.token = (try? ControlToken.loadOrCreate(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory())
        )) ?? ""
    }

    func start() {
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
                    let response = self.route(nextBuffer)
                    self.send(connection, status: response.status, data: response.data, error: response.error)
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
    private func route(_ data: Data) -> (status: Int, data: [String: Any]?, error: ControlErrorBody?) {
        guard let request = HTTPControlRequest(data: data) else {
            return (400, nil, ControlErrorBody(code: "invalid_http", message: "invalid HTTP request"))
        }

        guard let store else {
            return (500, nil, ControlErrorBody(code: "store_unavailable", message: "session store is unavailable"))
        }
        guard token.isEmpty || request.headers[ControlToken.headerName.lowercased()] == token else {
            return (401, nil, ControlErrorBody(code: "unauthorized", message: "invalid Banyan control token"))
        }

        do {
            guard let route = ControlRoute.resolve(method: request.method, path: request.path) else {
                return (404, nil, ControlErrorBody(code: "unknown_route", message: "unknown route"))
            }

            switch route {
            case .list:
                return (200, ["sessions": store.sessions.map(summary)], nil)

            case .select:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                store.select(id: id)
                return (200, ["session": summary(session)], nil)

            case .windowState:
                return (200, windowState(), nil)

            case .tick:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try store.tick(id: body.id)
                let visibleSessions = body.id.flatMap { id in
                    store.sessions.first(where: { $0.id == id }).map { [$0] }
                } ?? store.sessions
                return (200, ["sessions": visibleSessions.map(summary)], nil)

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
                return (200, ["session": summary(session)], nil)

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
                return (200, ["session": summary(session)], nil)

            case .close:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                try store.close(id: body.id!)
                return (200, ["ok": true], nil)

            case .respawn:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                try store.respawn(id: id)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return (200, ["session": summary(session)], nil)

            case .restart:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let id = body.id!
                try store.restart(id: id)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return (200, ["session": summary(session)], nil)

            case .remove:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                try store.remove(id: body.id!)
                return (200, ["ok": true], nil)

            case .screenshot:
                let body = try request.decode(ControlPayload.self)
                try validateVersion(body.apiVersion)
                try route.validate(body)
                let url = try VisualSnapshotter.captureMainWindow(to: body.path!)
                return (200, ["path": url.path], nil)
            }
        } catch let error as ControlError {
            return (error.httpStatus, nil, ControlErrorBody(code: error.code, message: error.localizedDescription))
        } catch let error as ControlValidationError {
            return (400, nil, ControlErrorBody(code: "missing_required_field", message: error.localizedDescription))
        } catch is DecodingError {
            return (400, nil, ControlErrorBody(code: "malformed_json", message: "malformed JSON request body"))
        } catch {
            return (400, nil, ControlErrorBody(code: "bad_request", message: error.localizedDescription))
        }
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
