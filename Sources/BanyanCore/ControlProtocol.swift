import Foundation

public enum ControlProtocol {
    public static let version = "v1"
    public static let headerTerminator = Data("\r\n\r\n".utf8)

    public static func isCompleteHTTPMessage(_ data: Data) -> Bool {
        guard let range = data.range(of: headerTerminator),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return false
        }
        return data.count >= range.upperBound + contentLength(from: header)
    }

    public static func contentLength(from header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1]) ?? 0
            }
        }
        return 0
    }
}

public struct HTTPControlRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init?(data: Data) {
        guard ControlProtocol.isCompleteHTTPMessage(data),
              let range = data.range(of: ControlProtocol.headerTerminator),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        method = parts[0]
        path = parts[1]
        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                parsedHeaders[parts[0].lowercased()] = parts[1]
            }
        }
        headers = parsedHeaders
        let length = ControlProtocol.contentLength(from: header)
        let bodyStart = range.upperBound
        body = data[bodyStart..<bodyStart + length]
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if body.isEmpty {
            return try JSONDecoder().decode(T.self, from: Data("{}".utf8))
        }
        return try JSONDecoder().decode(T.self, from: body)
    }
}

public struct ControlToken {
    public static let headerName = "X-Banyan-Token"

    public static func loadOrCreate() throws -> String {
        let url = tokenFileURL()
        if let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = UUID().uuidString + UUID().uuidString
        try token.write(to: url, atomically: true, encoding: .utf8)
        return token
    }

    public static func tokenFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Banyan/control-token")
    }
}

public struct ControlPayload: Codable {
    public let apiVersion: String?
    public let id: String?
    public let title: String?
    public let cwd: String?
    public let command: String?
    public let status: String?
    public let tone: String?

    public init(
        apiVersion: String? = ControlProtocol.version,
        id: String? = nil,
        title: String? = nil,
        cwd: String? = nil,
        command: String? = nil,
        status: String? = nil,
        tone: String? = nil
    ) {
        self.apiVersion = apiVersion
        self.id = id
        self.title = title
        self.cwd = cwd
        self.command = command
        self.status = status
        self.tone = tone
    }
}

public enum ControlRoute: Equatable {
    case list
    case spawn
    case mark
    case close
    case respawn
    case remove

    public static func resolve(method: String, path: String) -> ControlRoute? {
        switch (method, path) {
        case ("GET", "/list"): return .list
        case ("POST", "/spawn"): return .spawn
        case ("POST", "/mark"): return .mark
        case ("POST", "/close"): return .close
        case ("POST", "/respawn"): return .respawn
        case ("POST", "/remove"): return .remove
        default: return nil
        }
    }

    public var requiresID: Bool {
        switch self {
        case .mark, .close, .respawn, .remove: return true
        case .list, .spawn: return false
        }
    }

    public func validate(_ payload: ControlPayload) throws {
        if requiresID, payload.id?.isEmpty != false {
            throw ControlValidationError.missingID
        }
    }
}

public enum ControlValidationError: LocalizedError, Equatable {
    case missingID

    public var errorDescription: String? {
        switch self {
        case .missingID: return "request requires id"
        }
    }
}

public struct ControlEnvelope<T: Encodable>: Encodable {
    public let apiVersion: String
    public let ok: Bool
    public let data: T?
    public let error: ControlErrorBody?

    public init(ok: Bool, data: T? = nil, error: ControlErrorBody? = nil) {
        self.apiVersion = ControlProtocol.version
        self.ok = ok
        self.data = data
        self.error = error
    }
}

public struct ControlErrorBody: Codable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
