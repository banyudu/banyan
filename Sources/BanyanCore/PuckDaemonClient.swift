@_exported import PuckSwift
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Local app link target for a session shared with another frontend.
/// Slack links can redirect here after opening an HTTPS page.
public enum PuckSessionLink {
    public static func sessionID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "banyan",
              url.host?.lowercased() == "puck",
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2 else { return nil }
        let id = url.lastPathComponent
        guard !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                  (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
              }) else { return nil }
        return id
    }
}
