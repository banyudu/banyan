import Foundation

/// Pure naming rules for sessions created by resuming imported agent history.
public enum SessionResumePolicy {
    /// Returns the stable prefix used before the session ID allocator adds a
    /// suffix when the prefix is already occupied.
    public static func sessionIDPrefix(
        provider: CodingAgentProvider,
        sourceID: String
    ) -> String {
        "\(provider.rawValue)-\(sourceID.prefix(8))"
    }
}
