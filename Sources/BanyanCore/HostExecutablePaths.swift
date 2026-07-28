import Foundation

/// System executable directories searched by Banyan's host integrations.
public enum HostExecutablePaths {
    public static func userPaths(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/go/bin",
            "\(homeDirectory)/.nix-profile/bin"
        ]
    }

    public static func systemPaths() -> [String] {
        #if os(macOS)
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        #else
        return [
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        #endif
    }
}
