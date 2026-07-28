import BanyanCore
import Foundation

/// Compatibility facade while process-environment construction lives in core.
enum AppProcessEnvironment {
    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment,
        pathAdditions: [String] = [],
        removeKeys: Set<String> = [],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        BanyanCore.AppProcessEnvironment.make(
            base: base,
            pathAdditions: pathAdditions,
            removeKeys: removeKeys,
            overrides: overrides
        )
    }

    static func mergeAllowedShellEnvironment(
        _ shellEnvironment: [String: String],
        into environment: inout [String: String],
        allowlist: Set<String>? = nil
    ) {
        BanyanCore.AppProcessEnvironment.mergeAllowedShellEnvironment(
            shellEnvironment,
            into: &environment,
            allowlist: allowlist
        )
    }

    static func mergePath(
        into environment: inout [String: String],
        pathAdditions: [String],
        shellPath: String?
    ) {
        BanyanCore.AppProcessEnvironment.mergePath(
            into: &environment,
            pathAdditions: pathAdditions,
            shellPath: shellPath
        )
    }

    static func parseEnvironmentOutput(_ data: Data) -> [String: String] {
        BanyanCore.AppProcessEnvironment.parseEnvironmentOutput(data)
    }
}
