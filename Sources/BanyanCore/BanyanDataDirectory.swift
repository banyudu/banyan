import Foundation

/// Shared location policy for Banyan's per-user data files.
public enum BanyanDataDirectory {
    /// Explicit isolation for process fixtures. Unset in normal app/TUI runs.
    public static func fixtureDataHome(environment: [String: String]) -> URL? {
        guard let path = environment["BANYAN_FIXTURE_DATA_HOME"],
              (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    public static func applicationSupportURL(
        fileManager: FileManager = .default,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        if let fixture = fixtureDataHome(environment: environment) { return fixture }
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

    public static func url(
        for relativePath: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        applicationSupportURL(
            environment: environment,
            homeDirectory: homeDirectory
        ).appendingPathComponent(relativePath)
    }
}
