import Foundation

public enum PathDisplayName {
    public static func make(path: String, homeDirectory: String) -> String {
        let url = URL(fileURLWithPath: canonicalPath(path)).standardizedFileURL
        let homeURL = URL(fileURLWithPath: canonicalPath(homeDirectory)).standardizedFileURL
        if url.path == homeURL.path {
            return "~"
        }
        if url.path.hasPrefix(homeURL.path + "/") {
            return "~/" + String(url.path.dropFirst(homeURL.path.count + 1))
        }
        return url.path
    }

    /// Returns an absolute, normalized path with symlinks resolved.
    public static func canonicalPath(_ path: String) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
