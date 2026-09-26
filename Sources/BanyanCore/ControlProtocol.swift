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

    public static func loadOrCreate(
        environment: [String: String],
        homeDirectory: URL
    ) throws -> String {
        let url = tokenFileURL(environment: environment, homeDirectory: homeDirectory)
        if let token = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let token = UUID().uuidString + UUID().uuidString
        try token.write(to: url, atomically: true, encoding: .utf8)
        return token
    }

    public static func tokenFileURL(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        BanyanDataDirectory.url(
            for: "Banyan/control-token",
            environment: environment,
            homeDirectory: homeDirectory
        )
    }
}

public struct ControlPayload: Codable {
    public let apiVersion: String?
    public let id: String?
    public let title: String?
    public let titleURL: String?
    public let cwd: String?
    public let command: String?
    public let status: String?
    public let tone: String?
    public let parent: String?
    public let path: String?
    /// Optional "true"/"false" flag on spawn: whether the new session should grab
    /// focus/selection. Absent means "let the app decide" (background unless nothing
    /// is currently selected).
    public let focus: String?
    /// `/output`: how many rows of pane text to return.
    public let lines: LenientInt?
    /// `/input`: named keys to press, e.g. `["Down", "Enter"]`.
    public let keys: [String]?
    /// `/input`: text typed verbatim, never read as key names.
    public let text: String?
    /// `/input`: append Enter after `keys`/`text`.
    public let submit: LenientBool?
    /// `/answer`: 1-based option index from the preceding `/output`.
    public let option: LenientInt?
    /// `/answer`: `yes` / `no` / `always`.
    public let choice: String?
    /// `/answer`: accept whichever option the agent has highlighted.
    public let confirm: LenientBool?
    /// `/answer`: the `footprint` of the prompt the human was shown.
    public let footprint: String?
    /// `/events`: the highest cursor the client has already seen.
    public let since: LenientInt?
    /// `/suggest`: why the suggestion is worth attention, shown under the title.
    public let detail: String?
    /// `/suggest`: the idempotency key. Absent falls back to `target`, then to
    /// the command.
    public let key: String?
    /// `/suggest`: the opaque subject (issue id, URL) the suggestion is about.
    public let target: String?
    /// `/suggest`: `session` or `background`, matching a palette command's `run`.
    public let run: String?
    /// `/suggest`: how many seconds the suggestion stays live, holding the
    /// pending slot and suppressing its own key.
    public let ttl: LenientInt?
    /// `/prune`: the retention window to apply, in days. Absent uses the app's
    /// configured one; `0` keeps everything.
    public let days: LenientInt?
    /// `/prune`: report what would be removed and remove nothing.
    public let dryRun: LenientBool?

    public init(
        apiVersion: String? = ControlProtocol.version,
        id: String? = nil,
        title: String? = nil,
        titleURL: String? = nil,
        cwd: String? = nil,
        command: String? = nil,
        status: String? = nil,
        tone: String? = nil,
        parent: String? = nil,
        path: String? = nil,
        focus: String? = nil,
        lines: Int? = nil,
        keys: [String]? = nil,
        text: String? = nil,
        submit: Bool? = nil,
        option: Int? = nil,
        choice: String? = nil,
        confirm: Bool? = nil,
        footprint: String? = nil,
        since: Int? = nil,
        detail: String? = nil,
        key: String? = nil,
        target: String? = nil,
        run: String? = nil,
        ttl: Int? = nil,
        days: Int? = nil,
        dryRun: Bool? = nil
    ) {
        self.apiVersion = apiVersion
        self.id = id
        self.title = title
        self.titleURL = titleURL
        self.cwd = cwd
        self.command = command
        self.status = status
        self.tone = tone
        self.parent = parent
        self.path = path
        self.focus = focus
        self.lines = lines.map(LenientInt.init(value:))
        self.keys = keys
        self.text = text
        self.submit = submit.map(LenientBool.init(value:))
        self.option = option.map(LenientInt.init(value:))
        self.choice = choice
        self.confirm = confirm.map(LenientBool.init(value:))
        self.footprint = footprint
        self.since = since.map(LenientInt.init(value:))
        self.detail = detail
        self.key = key
        self.target = target
        self.run = run
        self.ttl = ttl.map(LenientInt.init(value:))
        self.days = days.map(LenientInt.init(value:))
        self.dryRun = dryRun.map(LenientBool.init(value:))
    }
}

/// An integer that decodes from a JSON number or from its string spelling.
///
/// `banyanctl` posts a flat string dictionary, while a bridge written against the
/// documented JSON shape sends `{"option": 2}`. Both are the same request, so both
/// decode rather than one of them being a 400 nobody can explain.
public struct LenientInt: Codable, Sendable, Equatable {
    public let value: Int

    public init(value: Int) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
            return
        }
        let raw = try container.decode(String.self)
        guard let number = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected an integer, got '\(raw)'")
        }
        value = number
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A boolean that decodes from a JSON bool or from `"true"` / `"false"`.
public struct LenientBool: Codable, Sendable, Equatable {
    public let value: Bool

    public init(value: Bool) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            value = flag
            return
        }
        let raw = try container.decode(String.self)
        guard let flag = Bool(raw.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected a boolean, got '\(raw)'")
        }
        value = flag
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ControlRoute: Equatable {
    case list
    case select
    case spawn
    case mark
    case close
    case respawn
    case restart
    case remove
    case screenshot
    case windowState
    case tick
    case suspend
    case resume
    /// Reads a session's pane: its text, and the prompt it is blocked on.
    case output
    /// Writes raw keys or literal text into a session's pane.
    case input
    /// Answers a parsed prompt by its footprint.
    case answer
    /// Long-polls for status transitions.
    case events
    /// Parks a proposal in the app's UI, to run only if a human approves it.
    case suggest
    /// Drops closed sessions that aged out of the retention window, or reports
    /// how many would go.
    case prune

    public static func resolve(method: String, path: String) -> ControlRoute? {
        switch (method, ControlRoute.normalizedPath(path)) {
        case ("GET", "/list"): return .list
        case ("GET", "/window-state"): return .windowState
        case ("GET", "/output"): return .output
        case ("GET", "/events"): return .events
        case ("POST", "/select"): return .select
        case ("POST", "/spawn"): return .spawn
        case ("POST", "/mark"): return .mark
        case ("POST", "/close"): return .close
        case ("POST", "/respawn"): return .respawn
        case ("POST", "/restart"): return .restart
        case ("POST", "/remove"): return .remove
        case ("POST", "/screenshot"): return .screenshot
        case ("POST", "/tick"): return .tick
        case ("POST", "/suspend"): return .suspend
        case ("POST", "/resume"): return .resume
        case ("POST", "/input"): return .input
        case ("POST", "/answer"): return .answer
        case ("POST", "/suggest"): return .suggest
        case ("POST", "/prune"): return .prune
        default: return nil
        }
    }

    /// Drops the query string. `/output` and `/events` are documented as GETs with
    /// parameters, and route matching happens before those are read.
    public static func normalizedPath(_ path: String) -> String {
        guard let separator = path.firstIndex(of: "?") else { return path }
        return String(path[..<separator])
    }

    /// Parses `a=b&c=d` from a request path into a payload's string fields.
    public static func queryItems(in path: String) -> [String: String] {
        guard let separator = path.firstIndex(of: "?") else { return [:] }
        var items: [String: String] = [:]
        for pair in path[path.index(after: separator)...].split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            items[name] = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return items
    }

    public var requiresID: Bool {
        switch self {
        case .select, .mark, .close, .respawn, .restart, .remove, .suspend, .resume,
             .output, .input, .answer: return true
        case .list, .spawn, .screenshot, .windowState, .tick, .events, .suggest,
             .prune: return false
        }
    }

    public func validate(_ payload: ControlPayload) throws {
        if requiresID, payload.id?.isEmpty != false {
            throw ControlValidationError.missingID
        }
        if self == .screenshot, payload.path?.isEmpty != false {
            throw ControlValidationError.missingPath
        }
        if self == .input, payload.keys?.isEmpty != false, payload.text?.isEmpty != false,
           payload.submit?.value != true {
            throw ControlValidationError.missingInput
        }
        if self == .answer, payload.footprint?.isEmpty != false {
            throw ControlValidationError.missingFootprint
        }
        if self == .suggest {
            // A suggestion the human cannot read, or that proposes nothing, is
            // worse than no suggestion: it occupies the one pending slot.
            if payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw ControlValidationError.missingTitle
            }
            if payload.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                throw ControlValidationError.missingCommand
            }
        }
    }
}

public enum ControlValidationError: LocalizedError, Equatable {
    case missingID
    case missingPath
    case missingInput
    case missingFootprint
    case missingTitle
    case missingCommand

    public var errorDescription: String? {
        switch self {
        case .missingID: return "request requires id"
        case .missingPath: return "request requires path"
        case .missingInput: return "request requires keys, text or submit"
        case .missingFootprint: return "request requires the footprint from a preceding /output"
        case .missingTitle: return "request requires title"
        case .missingCommand: return "request requires command"
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
