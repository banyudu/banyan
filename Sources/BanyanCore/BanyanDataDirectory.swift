import Foundation

/// Shared location policy for Banyan's per-user data files.
public enum BanyanDataDirectory {
    public static func applicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    public static func url(for relativePath: String) -> URL {
        applicationSupportURL().appendingPathComponent(relativePath)
    }
}
