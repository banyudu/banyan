import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BanyanCtl {
    func get(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 5) throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(String(path.dropFirst())),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw CLIError.message("could not build a request URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // `/events` holds the request open until a session changes status, so it
        // needs to outlast the server's own hold rather than time out under it.
        request.timeoutInterval = timeout
        try authorize(&request)
        try send(request)
    }

    func post(_ path: String, payload: [String: String]) throws {
        try postJSON(path, payload: payload)
    }

    func runSessionTitleMCP(id: String) {
        // Read blocks until a provider sends a message or closes stdin. No
        // timer, transcript scan, or model call runs while this helper is idle.
        while let line = readLine() {
            if let response = SessionTitleMCP.response(to: Data(line.utf8), updateTitle: { title in
                try updateSessionTitle(id: id, title: title)
            }) {
                FileHandle.standardOutput.write(response + Data([0x0a]))
            }
        }
    }

    func updateSessionTitle(id: String, title: String) throws -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("session-title"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apiVersion": ControlProtocol.version, "id": id, "title": title])
        let response = try exchange(request)
        guard response.statusCode < 400 else { throw CLIError.http(response.statusCode) }
        guard let data = response.data,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = body["data"] as? [String: Any],
              let applied = payload["applied"] as? Bool else { throw CLIError.message("Invalid session title response") }
        return applied
    }

    func postJSON(_ path: String, payload: [String: Any]) throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        var versionedPayload = payload
        versionedPayload["apiVersion"] = ControlProtocol.version
        request.httpBody = try JSONSerialization.data(withJSONObject: versionedPayload, options: [.sortedKeys])
        try send(request)
    }

    func authorize(_ request: inout URLRequest) throws {
        let token = try ControlToken.loadOrCreate(
            environment: host.environment,
            homeDirectory: host.homeDirectory
        )
        request.setValue(token, forHTTPHeaderField: ControlToken.headerName)
    }

    func send(_ request: URLRequest) throws {
        let result = try exchange(request)
        if let data = result.data, let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        if result.statusCode >= 400 {
            throw CLIError.http(result.statusCode)
        }
    }

    func exchange(_ request: URLRequest) throws -> HTTPResponseBox.Value {
        let semaphore = DispatchSemaphore(value: 0)
        let responseBox = HTTPResponseBox()

        URLSession.shared.dataTask(with: request) { data, httpResponse, error in
            responseBox.store(
                data: data,
                error: error,
                statusCode: (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
            )
            semaphore.signal()
        }.resume()
        semaphore.wait()

        let result = responseBox.value
        if result.error != nil {
            throw CLIError.serverUnavailable
        }
        return result
    }
}

final class HTTPResponseBox: @unchecked Sendable {
    struct Value {
        let data: Data?
        let error: Error?
        let statusCode: Int
    }

    private let lock = NSLock()
    private var storedValue = Value(data: nil, error: nil, statusCode: 0)

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(data: Data?, error: Error?, statusCode: Int) {
        lock.lock()
        storedValue = Value(data: data, error: error, statusCode: statusCode)
        lock.unlock()
    }
}
