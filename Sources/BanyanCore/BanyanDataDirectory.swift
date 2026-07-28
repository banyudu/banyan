import Foundation

/// Shared location policy for Banyan's per-user data files.
public enum BanyanDataDirectory {
    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        #if os(macOS)
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent("Library/Application Support")
        #else
        if let xdgDataHome = environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            return URL(fileURLWithPath: xdgDataHome)
        }
        return homeDirectory.appendingPathComponent(".local/share")
        #endif
    }

    public static func url(for relativePath: String) -> URL {
        applicationSupportURL().appendingPathComponent(relativePath)
    }
}
