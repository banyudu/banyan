import Foundation

public enum AppProcessEnvironment {
    private static let shellEnvironmentMarker = "__BANYAN_SHELL_ENV_START__"

    /// Spawning a login+interactive shell costs ~1.5s on a typical setup, but it is now
    /// paid once per shell per app run rather than once per caller, so the budget can be
    /// generous. The old 3s limit was routinely exceeded on a loaded machine, and every
    /// timeout leaked a thread (see `loadShellEnvironment`).
    private static let defaultShellEnvironmentTimeout: TimeInterval = 15

    private static var shellEnvironmentTimeout: TimeInterval {
        shellEnvironmentTimeoutOverrideForTesting ?? defaultShellEnvironmentTimeout
    }

    /// How long a failed load is remembered before another shell is spawned. Caching the
    /// failure keeps a persistently slow shell from being re-spawned by every caller;
    /// expiring it keeps a transient failure from disabling tokens for the whole session.
    private static let shellEnvironmentRetryInterval: TimeInterval = 60

    /// Grace given to a timed-out shell to exit from SIGTERM before it is SIGKILLed.
    private static let shellTerminationGrace: TimeInterval = 1

    private struct ShellEnvironmentCacheEntry {
        let environment: [String: String]
        /// `nil` means the entry never expires; only failed loads are given an expiry.
        let expiresAt: Date?

        func isValid(at date: Date) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt > date
        }
    }

    /// Guards `shellEnvironmentCache` and `shellEnvironmentLoadsInFlight`, and lets
    /// callers that arrive during a load wait for its result instead of spawning a
    /// duplicate shell.
    private static let shellEnvironmentCondition = NSCondition()
    nonisolated(unsafe) private static var shellEnvironmentCache: [String: ShellEnvironmentCacheEntry] = [:]
    nonisolated(unsafe) private static var shellEnvironmentLoadsInFlight: Set<String> = []

    private static let defaultShellEnvironmentAllowlist: Set<String> = [
        "BANYAN_LINEAR_BASE_URL",
        "BANYAN_LINEAR_ORG",
        "BANYAN_SHELL_ENV_ALLOWLIST",
        "BANYAN_TITLE_COMMAND",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "LINEAR_API_KEY"
    ]

    /// The login shell's exported environment, resolved once per shell and cached.
    ///
    /// This used to spawn a shell on every call, and the hot callers are pollers
    /// (`LinearIssueClient`, `GitHubIssueClient`, `GitHubPullRequestClient`,
    /// `SessionStore`), so the app spawned a login shell every few seconds for its
    /// whole lifetime. The result does not change while the app runs, so it is cached.
    public static func shellEnvironment(environment: [String: String]) -> [String: String] {
        let shell = HostShell.executablePath(environment: environment)

        shellEnvironmentCondition.lock()
        while true {
            if let entry = shellEnvironmentCache[shell], entry.isValid(at: Date()) {
                shellEnvironmentCondition.unlock()
                return entry.environment
            }
            guard shellEnvironmentLoadsInFlight.contains(shell) else { break }
            // Another caller is already spawning this shell; wait for its result rather
            // than piling on. Bounded so a wedged loader cannot park callers forever.
            let deadline = Date().addingTimeInterval(shellEnvironmentTimeout + shellTerminationGrace * 2)
            guard shellEnvironmentCondition.wait(until: deadline) else {
                shellEnvironmentCondition.unlock()
                return [:]
            }
        }
        shellEnvironmentLoadsInFlight.insert(shell)
        shellEnvironmentCondition.unlock()

        let loaded = loadShellEnvironment(shell: shell)

        shellEnvironmentCondition.lock()
        shellEnvironmentCache[shell] = ShellEnvironmentCacheEntry(
            environment: loaded,
            expiresAt: loaded.isEmpty ? Date().addingTimeInterval(shellEnvironmentRetryInterval) : nil
        )
        shellEnvironmentLoadsInFlight.remove(shell)
        shellEnvironmentCondition.broadcast()
        shellEnvironmentCondition.unlock()

        return loaded
    }

    /// Resolves the shell environment off the calling thread so the first real caller
    /// does not pay shell startup synchronously.
    public static func prewarmShellEnvironment(environment: [String: String]) {
        DispatchQueue.global(qos: .utility).async {
            _ = shellEnvironment(environment: environment)
        }
    }

    // MARK: - Testing hooks

    /// Shortens the timeout so tests can exercise the timeout path without waiting the
    /// full production budget.
    nonisolated(unsafe) internal static var shellEnvironmentTimeoutOverrideForTesting: TimeInterval?

    internal static func resetShellEnvironmentCacheForTesting() {
        shellEnvironmentCondition.lock()
        shellEnvironmentCache.removeAll()
        shellEnvironmentCondition.unlock()
    }

    public static func make(
        base: [String: String],
        shellEnvironment: [String: String],
        pathAdditions: [String] = [],
        removeKeys: Set<String> = [],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        mergeAllowedShellEnvironment(shellEnvironment, into: &environment)
        mergePath(into: &environment, pathAdditions: pathAdditions, shellPath: shellEnvironment["PATH"])

        for key in removeKeys {
            environment.removeValue(forKey: key)
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    public static func mergeAllowedShellEnvironment(
        _ shellEnvironment: [String: String],
        into environment: inout [String: String],
        allowlist: Set<String>? = nil
    ) {
        let keys = allowlist ?? shellEnvironmentAllowlist(base: environment, shell: shellEnvironment)
        for key in keys {
            guard environment[key]?.isEmpty ?? true,
                  let value = shellEnvironment[key],
                  !value.isEmpty
            else {
                continue
            }
            environment[key] = value
        }
    }

    public static func mergePath(
        into environment: inout [String: String],
        pathAdditions: [String],
        shellPath: String?
    ) {
        let currentPath = environment["PATH"] ?? ""
        let pathEntries = pathAdditions
            + splitPath(shellPath)
            + splitPath(currentPath)

        environment["PATH"] = pathEntries.reduce(into: [String]()) { paths, path in
            if !path.isEmpty, !paths.contains(path) {
                paths.append(path)
            }
        }.joined(separator: ":")
    }

    public static func parseEnvironmentOutput(_ data: Data) -> [String: String] {
        let markerData = Data("\n\(shellEnvironmentMarker)\n".utf8)
        guard let markerRange = data.range(of: markerData) else {
            return [:]
        }

        return data[markerRange.upperBound...]
            .split(separator: 0)
            .reduce(into: [String: String]()) { environment, entry in
                guard let separatorIndex = entry.firstIndex(of: UInt8(ascii: "=")) else {
                    return
                }
                let keyData = entry[..<separatorIndex]
                let valueData = entry[entry.index(after: separatorIndex)...]
                guard let key = String(data: Data(keyData), encoding: .utf8),
                      !key.isEmpty,
                      let value = String(data: Data(valueData), encoding: .utf8)
                else {
                    return
                }
                environment[key] = value
            }
    }

    private static func loadShellEnvironment(shell: String) -> [String: String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-i` is load-bearing: zsh sources ~/.zshrc only for interactive shells, and
        // that is where most PATH and token exports live. A plain `-lc` would be faster
        // but would silently drop them.
        process.arguments = [
            "-ilc",
            "printf '\\n\(shellEnvironmentMarker)\\n'; /usr/bin/env -0"
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Both pipes must be drained while the shell runs. A shell that fills the ~64KB
        // pipe buffer blocks on write and never exits, which would defeat the timeout
        // below and make the process unkillable by SIGTERM.
        let outputDrain = PipeDrain(stdout.fileHandleForReading)
        let errorDrain = PipeDrain(stderr.fileHandleForReading)
        defer {
            outputDrain.stop()
            errorDrain.stop()
        }

        // terminationHandler fires on a Foundation-internal queue once the child is
        // reaped. waitUntilExit() would instead park a thread from the global pool for
        // the child's lifetime, and on the timeout path that thread was never released:
        // each timed-out load leaked one until libdispatch's 80-thread soft limit was
        // reached and the whole app starved.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return [:]
        }

        if exited.wait(timeout: .now() + shellEnvironmentTimeout) != .success {
            process.terminate()
            if exited.wait(timeout: .now() + shellTerminationGrace) != .success {
                // A shell that ignores SIGTERM would otherwise linger as a zombie.
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + shellTerminationGrace)
            }
            return [:]
        }

        guard process.terminationStatus == 0 else { return [:] }

        // The child has exited; let the drain observe EOF so no trailing output is lost.
        outputDrain.waitForEnd(timeout: shellTerminationGrace)
        return parseEnvironmentOutput(outputDrain.collected)
    }

    private static func splitPath(_ value: String?) -> [String] {
        value?.split(separator: ":").map(String.init) ?? []
    }

    private static func shellEnvironmentAllowlist(
        base: [String: String],
        shell: [String: String]
    ) -> Set<String> {
        defaultShellEnvironmentAllowlist
            .union(configuredAllowlist(in: base))
            .union(configuredAllowlist(in: shell))
    }

    private static func configuredAllowlist(in environment: [String: String]) -> Set<String> {
        guard let value = environment["BANYAN_SHELL_ENV_ALLOWLIST"] else {
            return []
        }
        let separators = CharacterSet(charactersIn: ",: \n\t")
        return Set(value.components(separatedBy: separators).filter { !$0.isEmpty })
    }
}

/// Consumes a pipe on Foundation's readability queue so a child process can never block
/// writing into a full pipe buffer, and reports when the write end closes.
///
/// Reading the pipe only after the child exits (the obvious alternative) deadlocks for
/// any child whose output exceeds the buffer, because the child cannot exit until the
/// buffer is drained.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var isFinished = false
    private let ended = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // Empty read means EOF: the child closed its end.
                finish()
                return
            }
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }
    }

    var collected: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func waitForEnd(timeout: TimeInterval) {
        _ = ended.wait(timeout: .now() + timeout)
    }

    /// Idempotent. Also breaks the handle -> handler -> self retain cycle.
    func stop() {
        finish()
    }

    private func finish() {
        lock.lock()
        let wasFinished = isFinished
        isFinished = true
        lock.unlock()
        guard !wasFinished else { return }
        handle.readabilityHandler = nil
        ended.signal()
    }
}
