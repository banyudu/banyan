import Foundation

/// System executable directories searched by Banyan's host integrations.
public enum HostExecutablePaths {
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
