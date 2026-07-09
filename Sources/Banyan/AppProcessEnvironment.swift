import Foundation

enum AppProcessEnvironment {
    private static let shellEnvironmentMarker = "__BANYAN_SHELL_ENV_START__"
    private static let shellEnvironmentTimeout: TimeInterval = 3

    private static let defaultShellEnvironmentAllowlist: Set<String> = [
        "BANYAN_LINEAR_BASE_URL",
        "BANYAN_LINEAR_ORG",
        "BANYAN_SHELL_ENV_ALLOWLIST",
        "BANYAN_TITLE_COMMAND",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "LINEAR_API_KEY"
    ]

    private static let cachedShellEnvironment: [String: String] = loadShellEnvironment()

    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        pathAdditions: [String] = [],
        removeKeys: Set<String> = [],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = base
        mergeAllowedShellEnvironment(cachedShellEnvironment, into: &environment)
        mergePath(into: &environment, pathAdditions: pathAdditions, shellPath: cachedShellEnvironment["PATH"])

        for key in removeKeys {
            environment.removeValue(forKey: key)
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    static func mergeAllowedShellEnvironment(
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

    static func mergePath(
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

    static func parseEnvironmentOutput(_ data: Data) -> [String: String] {
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

    private static func loadShellEnvironment() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [
            "-ilc",
            "printf '\\n\(shellEnvironmentMarker)\\n'; /usr/bin/env -0"
        ]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return [:]
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + shellEnvironmentTimeout) == .success else {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            return [:]
        }
        guard process.terminationStatus == 0 else { return [:] }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return parseEnvironmentOutput(data)
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
