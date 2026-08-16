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
            let deadline = Date()
                .addingTimeInterval(shellEnvironmentTimeout + SubprocessRunner.terminationBudget)
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

    /// Spawns the login shell through `SubprocessRunner`.
    ///
    /// This used to drive `Process` directly with a `FileHandle.readabilityHandler`
    /// drain per pipe. On Linux each of those handlers is a dispatch source on its
    /// own private serial queue, so every load left two pool threads behind — the
    /// leak `timeoutLeavesNoParkedThreadsOrZombies` measures. `SubprocessRunner`
    /// reads the pipes inline instead: no dispatch source, no extra thread, and the
    /// SIGTERM-then-SIGKILL escalation this path needs comes with it.
    private static func loadShellEnvironment(shell: String) -> [String: String] {
        let output: SubprocessRunner.Output
        do {
            output = try SubprocessRunner.run(
                arguments: [
                    shell,
                    // `-i` is load-bearing: zsh sources ~/.zshrc only for interactive
                    // shells, and that is where most PATH and token exports live. A
                    // plain `-lc` would be faster but would silently drop them.
                    "-ilc",
                    "printf '\\n\(shellEnvironmentMarker)\\n'; /usr/bin/env -0"
                ],
                cwd: FileManager.default.currentDirectoryPath,
                environment: ProcessInfo.processInfo.environment,
                timeout: shellEnvironmentTimeout,
                standardInput: FileHandle.nullDevice
            )
        } catch {
            return [:]
        }

        guard output.terminationStatus == 0 else { return [:] }
        return parseEnvironmentOutput(output.standardOutput)
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
