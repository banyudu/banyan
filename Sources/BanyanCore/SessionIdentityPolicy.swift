import Foundation

/// Backend-neutral identity rules for persisted sessions.
public enum SessionIdentityPolicy {
    public static func sessionName(for id: String) -> String {
        "banyan-\(id)"
    }
}
