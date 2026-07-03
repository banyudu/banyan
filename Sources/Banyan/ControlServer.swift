import Foundation
import Network

final class ControlServer {
    private weak var store: SessionStore?
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 7842

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: DispatchQueue(label: "app.banyan.control-server"))
            self.listener = listener
        } catch {
            NSLog("Banyan control server failed to start: \(error.localizedDescription)")
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
                self.send(connection, status: 500, payload: ["error": error.localizedDescription])
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if self.hasCompleteRequest(nextBuffer) {
                Task { @MainActor in
                    let response = self.route(nextBuffer)
                    self.send(connection, status: response.status, payload: response.payload)
                }
                return
            }

            if isComplete {
                self.send(connection, status: 400, payload: ["error": "empty request"])
                return
            }

            self.receiveRequest(connection, buffer: nextBuffer)
        }
    }

    private func hasCompleteRequest(_ data: Data) -> Bool {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker) else {
            return false
        }
        let headerData = data[..<range.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else {
            return false
        }
        let contentLength = HTTPControlRequest.contentLength(from: header)
        return data.count >= range.upperBound + contentLength
    }

    @MainActor
    private func route(_ data: Data) -> (status: Int, payload: [String: Any]) {
        guard let request = HTTPControlRequest(data: data) else {
            return (400, ["error": "invalid HTTP request"])
        }

        guard let store else {
            return (500, ["error": "session store is unavailable"])
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/list"):
                return (200, ["sessions": store.sessions.map(summary)])

            case ("POST", "/spawn"):
                let body = try request.decode(ControlPayload.self)
                let tone = body.tone.flatMap(SessionTone.init(rawValue:)) ?? .blue
                let session = store.spawn(
                    id: body.id,
                    title: body.title,
                    cwd: body.cwd,
                    command: body.command,
                    tone: tone
                )
                return (200, ["session": summary(session)])

            case ("POST", "/mark"):
                let body = try request.decode(ControlPayload.self)
                guard let id = body.id else {
                    throw ControlError.badRequest("mark requires id")
                }
                let status = try body.status.map(parseStatus)
                let tone = try body.tone.map(parseTone)
                try store.mark(id: id, status: status, tone: tone, title: body.title)
                guard let session = store.sessions.first(where: { $0.id == id }) else {
                    throw ControlError.notFound(id)
                }
                return (200, ["session": summary(session)])

            case ("POST", "/close"):
                let body = try request.decode(ControlPayload.self)
                guard let id = body.id else {
                    throw ControlError.badRequest("close requires id")
                }
                try store.close(id: id)
                return (200, ["ok": true])

            case ("POST", "/remove"):
                let body = try request.decode(ControlPayload.self)
                guard let id = body.id else {
                    throw ControlError.badRequest("remove requires id")
                }
                try store.remove(id: id)
                return (200, ["ok": true])

            default:
                return (404, ["error": "unknown route"])
            }
        } catch {
            return (400, ["error": error.localizedDescription])
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
    private func summary(_ session: BanyanSession) -> [String: Any] {
        [
            "id": session.id,
            "title": session.title,
            "reportedTitle": session.reportedTitle ?? "",
            "cwd": session.cwd,
            "command": session.command,
            "status": session.status.rawValue,
            "tone": session.tone.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: session.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt)
        ]
    }

    private func send(_ connection: NWConnection, status: Int, payload: [String: Any]) {
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

private struct ControlPayload: Codable {
    let id: String?
    let title: String?
    let cwd: String?
    let command: String?
    let status: String?
    let tone: String?
}

private struct HTTPControlRequest {
    let method: String
    let path: String
    let body: Data

    init?(data: Data) {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        self.method = parts[0]
        self.path = parts[1]
        let length = Self.contentLength(from: header)
        let bodyStart = range.upperBound
        let bodyEnd = min(data.count, bodyStart + length)
        self.body = data[bodyStart..<bodyEnd]
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if body.isEmpty {
            return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
        }
        return try JSONDecoder().decode(T.self, from: body)
    }

    static func contentLength(from header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1]) ?? 0
            }
        }
        return 0
    }
}
