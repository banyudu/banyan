import Foundation

/// Resolves a requested working directory using the host's current directory
/// and home directory as fallbacks.
public enum WorkingDirectoryPolicy {
    public static func resolve(
        proposedDirectory: String?,
        currentDirectory: String,
        homeDirectory: String
    ) -> String {
        let raw = proposedDirectory?.isEmpty == false ? proposedDirectory! : currentDirectory
        let expanded = NSString(string: raw).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return PathDisplayName.canonicalPath(expanded)
        }
        return PathDisplayName.canonicalPath(homeDirectory)
    }
}
