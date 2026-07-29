import Foundation

/// Backend-neutral identity rules for persisted sessions.
public enum SessionIdentityPolicy {
    public static func sanitizedID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "session" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let result = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return result.isEmpty ? "session" : result
    }

    public static func sessionName(for id: String) -> String {
        "banyan-\(id)"
    }

    public static func nextAvailableID(
        from baseID: String,
        isAvailable: (String) -> Bool
    ) -> String {
        guard !isAvailable(baseID) else { return baseID }
        var suffix = 2
        while !isAvailable("\(baseID)-\(suffix)") {
            suffix += 1
        }
        return "\(baseID)-\(suffix)"
    }
}
