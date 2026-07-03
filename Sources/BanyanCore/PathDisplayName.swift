import Foundation

public enum PathDisplayName {
    public static func make(path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let homeURL = URL(fileURLWithPath: homeDirectory).standardizedFileURL
        if url.path == homeURL.path {
            return "~"
        }
        if url.path.hasPrefix(homeURL.path + "/") {
            return "~/" + String(url.path.dropFirst(homeURL.path.count + 1))
        }
        return url.path
    }
}
