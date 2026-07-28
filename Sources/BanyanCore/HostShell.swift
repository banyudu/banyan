import Foundation

/// Resolves the interactive shell used when Banyan starts host commands.
public enum HostShell {
    public static func executablePath(
        environment: [String: String]
    ) -> String {
        if let configured = environment["SHELL"] {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        #if os(macOS)
        return "/bin/zsh"
        #else
        return "/bin/sh"
        #endif
    }

    public static func executableURL(
        environment: [String: String]
    ) -> URL {
        URL(fileURLWithPath: executablePath(environment: environment))
    }
}
