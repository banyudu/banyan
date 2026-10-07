import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// CLI/TUI turns share app admission while it is reachable. Only connection
/// refusal permits offline daemon delivery; never replay a timed-out request.
public enum PuckAppAdmission {
    public static func turn(_ id: String, prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
        let address = environment["BANYAN_FIXTURE_CONTROL_URL"] ?? "http://127.0.0.1:7842"
        guard let base = URL(string: address), base.scheme == "http", base.host == "127.0.0.1" else {
            throw PuckDaemonError.rejected("Invalid local Banyan control address")
        }
        var request = URLRequest(url: base.appendingPathComponent("puck-turn"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try ControlToken.loadOrCreate(environment: environment, homeDirectory: homeDirectory),
                         forHTTPHeaderField: ControlToken.headerName)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["apiVersion": ControlProtocol.version,
            "id": id, "text": prompt, "ttl": Int(Date().timeIntervalSince1970) + 4])
        let box = AdmissionHTTPResult()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.store(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
            done.signal()
        }.resume()
        done.wait()
        let result = box.value
        if let error = result.error as? URLError, error.code == .cannotConnectToHost { return false }
        if let error = result.error {
            throw PuckDaemonError.unavailable("Banyan turn delivery is uncertain; inspect the session before retrying. \(error.localizedDescription)")
        }
        guard let status = result.status, (200..<300).contains(status) else {
            let response = result.data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let message = (response?["error"] as? [String: Any])?["message"] as? String
            throw PuckDaemonError.rejected(message ?? "Banyan refused the turn (HTTP \(result.status ?? 0)); nothing was queued")
        }
        return true
    }
}

private final class AdmissionHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (data: Data?, status: Int?, error: Error?) = (nil, nil, nil)
    var value: (data: Data?, status: Int?, error: Error?) { lock.lock(); defer { lock.unlock() }; return result }
    func store(data: Data?, status: Int?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        result = (data, status, error)
    }
}
