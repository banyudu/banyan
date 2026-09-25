import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Values crossing the Codex adapter boundary. Unknown protocol fields remain
/// representable, so a newer notification cannot corrupt the transport.
public indirect enum CodexJSONValue: Codable, Sendable, Equatable {
    case object([String: CodexJSONValue])
    case array([CodexJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public var objectValue: [String: CodexJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: CodexJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([CodexJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum CodexAppServerError: Error, Sendable, Equatable, LocalizedError {
    case launch(String)
    case incompatibleVersion(String)
    case protocolViolation(String)
    case disconnected(String)
    case timedOut(String)
    case remote(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .launch(let reason): return "Codex App Server could not start: \(reason)"
        case .incompatibleVersion(let version): return "Codex App Server \(version) is not in Banyan's tested 0.146.x protocol range. Update Banyan or use the Codex CLI fallback."
        case .protocolViolation(let reason): return "Codex App Server protocol error: \(reason)"
        case .disconnected(let reason): return "Codex App Server disconnected: \(reason). Retry the operation to reconnect."
        case .timedOut(let method): return "Codex App Server request timed out: \(method)"
        case .remote(let code, let message): return "Codex App Server error \(code): \(message)"
        }
    }
}

public struct CodexServerRequest: Sendable {
    public let id: CodexJSONValue
    public let method: String
    public let params: CodexJSONValue
}

public enum CodexServerReply: Sendable {
    case result(CodexJSONValue)
    case error(code: Int, message: String)
}

public enum CodexAppServerEvent: Sendable {
    case notification(method: String, params: CodexJSONValue)
    case disconnected(CodexAppServerError)
}

/// One child per Banyan app process. The endpoint is its private stdin/stdout
/// pipe pair (`--listen stdio://`), never Codex Desktop's `unix://` socket.
/// `connect()` is lazy and coalesced; `stop()` belongs to app termination. After
/// an unexpected exit, the next operation starts a fresh child and handshake.
/// Requests in flight at exit fail; callers must explicitly resume threads.
public actor CodexAppServerClient {
    public typealias RequestHandler = @Sendable (CodexServerRequest) async -> CodexServerReply

    private struct Pending {
        let method: String
        let continuation: CheckedContinuation<CodexJSONValue, Error>
        let timeout: Task<Void, Never>
    }

    private let executable: String
    private let environmentProvider: @Sendable () -> [String: String]
    private let clientVersion: String
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var reader: Task<Void, Never>?
    private var priorExit: Task<Void, Never>?
    private var connectTask: Task<Void, Error>?
    private var generation = 0
    private var ready = false
    private var hostStopped = false
    private var nextID: Int64 = 1
    private var pending: [Int64: Pending] = [:]
    private var eventStreams: [UUID: AsyncStream<CodexAppServerEvent>.Continuation] = [:]
    private var requestHandler: RequestHandler?
    private var buffer = Data()

    public init(
        executable: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        environmentProvider: (@Sendable () -> [String: String])? = nil,
        clientVersion: String = "0.1.0",
        requestTimeout: TimeInterval = 30
    ) {
        self.executable = executable
        self.environmentProvider = environmentProvider ?? { environment }
        self.clientVersion = clientVersion
        self.requestTimeout = requestTimeout
    }

    public func events() -> AsyncStream<CodexAppServerEvent> {
        let id = UUID()
        // A stalled view must not retain an unbounded turn transcript. On
        // overflow its stream ends, and the view can reload from thread/read.
        return AsyncStream(bufferingPolicy: .bufferingOldest(1024)) { continuation in
            eventStreams[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventStream(id) }
            }
        }
    }

    public func setServerRequestHandler(_ handler: RequestHandler?) {
        requestHandler = handler
    }

    public func connect() async throws {
        guard !hostStopped else { throw CodexAppServerError.disconnected("Banyan is closing") }
        if ready { return }
        if let connectTask { return try await connectTask.value }
        let task = Task { try await startAndInitialize() }
        connectTask = task
        defer { connectTask = nil }
        try await task.value
    }

    public func request(_ method: String, params: CodexJSONValue = .object([:])) async throws -> CodexJSONValue {
        try await connect()
        try Task.checkCancellation()
        return try await sendRequest(method, params: params, generation: generation)
    }

    public func notify(_ method: String, params: CodexJSONValue = .object([:])) async throws {
        try await connect()
        try send(.object(["method": .string(method), "params": params]), generation: generation)
    }

    /// Called by the Banyan host during application termination. A bounded
    /// SIGTERM/SIGKILL sequence prevents an orphan if Codex ignores SIGTERM.
    public func stop() async {
        hostStopped = true
        await shutdown()
    }

    private func shutdown() async {
        generation += 1
        ready = false
        connectTask?.cancel()
        connectTask = nil
        failPending(.disconnected("Banyan is closing"))
        reader?.cancel()
        reader = nil
        output?.fileHandleForReading.readabilityHandler = nil
        let oldProcess = process
        process = nil
        input?.closeBothEnds()
        output?.closeBothEnds()
        input = nil
        output = nil
        buffer.removeAll()
        if let oldProcess { await Self.terminateAndReap(oldProcess) }
        await priorExit?.value
        priorExit = nil
    }

    private func startAndInitialize() async throws {
        guard !hostStopped else { throw CodexAppServerError.disconnected("Banyan is closing") }
        // A failed connection must finish reaping before a replacement starts.
        await priorExit?.value
        priorExit = nil
        guard !hostStopped else { throw CodexAppServerError.disconnected("Banyan is closing") }
        generation += 1
        let current = generation
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [executable, "app-server", "--listen", "stdio://"]
        child.environment = environmentProvider()
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            stdin.closeBothEnds()
            stdout.closeBothEnds()
            throw CodexAppServerError.launch(error.localizedDescription)
        }
        process = child
        input = stdin
        output = stdout
        buffer.removeAll()
        let chunks = AsyncStream<Data> { continuation in
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        reader = Task { [weak self] in
            for await chunk in chunks { await self?.consume(chunk, generation: current) }
            await self?.disconnect("server closed stdout", generation: current)
        }
        child.terminationHandler = { [weak self] exited in
            Task { await self?.disconnect("process exited with status \(exited.terminationStatus)", generation: current) }
        }
        do {
            let result = try await sendRequest("initialize", params: .object([
                "clientInfo": .object([
                    "name": .string("banyan"),
                    "title": .string("Banyan"),
                    "version": .string(clientVersion)
                ])
            ]), generation: current)
            guard generation == current else { throw CodexAppServerError.disconnected("connection replaced") }
            guard let userAgent = result.objectValue?["userAgent"]?.stringValue,
                  let version = Self.serverVersion(from: userAgent) else {
                throw CodexAppServerError.protocolViolation("initialize omitted a recognizable server version")
            }
            guard version.major == 0, version.minor == 146 else {
                throw CodexAppServerError.incompatibleVersion(version.description)
            }
            try send(.object(["method": .string("initialized"), "params": .object([:])]), generation: current)
            ready = true
        } catch {
            await shutdown()
            throw error
        }
    }

    private struct Version {
        let major: Int
        let minor: Int
        let patch: Int
        var description: String { "\(major).\(minor).\(patch)" }
    }

    private static func serverVersion(from userAgent: String) -> Version? {
        // The initialize userAgent begins with `<client>/<codex-version>`.
        guard let token = userAgent.split(separator: " ").first,
              let slash = token.firstIndex(of: "/") else { return nil }
        let parts = token[token.index(after: slash)...].split(separator: ".")
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        return Version(major: major, minor: minor, patch: patch)
    }

    private func sendRequest(_ method: String, params: CodexJSONValue, generation current: Int) async throws -> CodexJSONValue {
        let id = nextID
        nextID += 1
        let requestTimeout = requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(requestTimeout))
                        await self?.expire(id: id, generation: current)
                    } catch {}
                }
                pending[id] = Pending(method: method, continuation: continuation, timeout: timeout)
                do {
                    try send(.object(["id": .integer(id), "method": .string(method), "params": params]), generation: current)
                } catch {
                    finish(id: id, with: .failure(error))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancel(id: id, generation: current) }
        }
    }

    private func send(_ message: CodexJSONValue, generation current: Int) throws {
        guard current == generation, let input else {
            throw CodexAppServerError.disconnected("connection unavailable")
        }
        var data = try JSONEncoder().encode(message)
        data.append(0x0a)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch {
            disconnect("write failed: \(error.localizedDescription)", generation: current)
            throw CodexAppServerError.disconnected("write failed")
        }
    }

    private func consume(_ chunk: Data, generation current: Int) {
        guard current == generation, process != nil else { return }
        buffer.append(chunk)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0a) {
            guard newline - start <= 8 * 1024 * 1024 else {
                disconnect("JSONL message exceeded 8 MiB", generation: current)
                return
            }
            let line = Data(buffer[start..<newline])
            start = buffer.index(after: newline)
            if line.isEmpty { continue }
            guard let message = try? JSONDecoder().decode(CodexJSONValue.self, from: line),
                  let object = message.objectValue else {
                disconnect("invalid JSONL message", generation: current)
                return
            }
            route(object, generation: current)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
        if buffer.count > 8 * 1024 * 1024 {
            disconnect("JSONL message exceeded 8 MiB", generation: current)
        }
    }

    private func route(_ message: [String: CodexJSONValue], generation current: Int) {
        if let method = message["method"]?.stringValue {
            let params = message["params"] ?? .object([:])
            if let id = message["id"] {
                let request = CodexServerRequest(id: id, method: method, params: params)
                let handler = requestHandler
                Task { [weak self] in
                    let reply = await handler?(request) ?? .error(code: -32601, message: "Unsupported server request")
                    await self?.reply(to: request, with: reply, generation: current)
                }
            } else {
                emit(.notification(method: method, params: params))
            }
            return
        }
        guard case .integer(let id)? = message["id"] else { return }
        if let result = message["result"] {
            finish(id: id, with: .success(result))
        } else if let error = message["error"]?.objectValue {
            let code: Int = if case .integer(let value)? = error["code"] { Int(value) } else { -32000 }
            finish(id: id, with: .failure(CodexAppServerError.remote(
                code: code,
                message: error["message"]?.stringValue ?? "Unknown server error"
            )))
        } else {
            finish(id: id, with: .failure(CodexAppServerError.protocolViolation("response omitted result and error")))
        }
    }

    private func reply(to request: CodexServerRequest, with reply: CodexServerReply, generation current: Int) {
        var object: [String: CodexJSONValue] = ["id": request.id]
        switch reply {
        case .result(let value): object["result"] = value
        case .error(let code, let message):
            object["error"] = .object(["code": .integer(Int64(code)), "message": .string(message)])
        }
        do { try send(.object(object), generation: current) }
        catch { disconnect("could not send server-request reply", generation: current) }
    }

    private func expire(id: Int64, generation current: Int) {
        guard current == generation, let method = pending[id]?.method else { return }
        finish(id: id, with: .failure(CodexAppServerError.timedOut(method)))
    }

    private func cancel(id: Int64, generation current: Int) {
        guard current == generation else { return }
        finish(id: id, with: .failure(CancellationError()))
    }

    private func finish(id: Int64, with result: Result<CodexJSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(with: result)
    }

    private func failPending(_ error: CodexAppServerError) {
        for id in Array(pending.keys) { finish(id: id, with: .failure(error)) }
    }

    private func disconnect(_ reason: String, generation current: Int) {
        guard current == generation, process != nil else { return }
        let error = CodexAppServerError.disconnected(reason)
        ready = false
        failPending(error)
        output?.fileHandleForReading.readabilityHandler = nil
        reader?.cancel()
        reader = nil
        input?.closeBothEnds()
        output?.closeBothEnds()
        input = nil
        output = nil
        let oldProcess = process
        process = nil
        if let oldProcess {
            priorExit = Task { await Self.terminateAndReap(oldProcess) }
        }
        emit(.disconnected(error))
    }

    private static func terminateAndReap(_ child: Process) async {
        if child.isRunning {
            child.terminate()
            try? await Task.sleep(for: .milliseconds(500))
            if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        }
        await Task.detached { child.waitUntilExit() }.value
    }

    private func emit(_ event: CodexAppServerEvent) {
        var overflowed: [UUID] = []
        for (id, stream) in eventStreams {
            if case .dropped = stream.yield(event) {
                stream.finish()
                overflowed.append(id)
            }
        }
        for id in overflowed { eventStreams.removeValue(forKey: id) }
    }

    private func removeEventStream(_ id: UUID) {
        eventStreams.removeValue(forKey: id)
    }
}
