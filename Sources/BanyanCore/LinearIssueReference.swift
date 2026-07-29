import Foundation

public struct LinearIssueReference: Equatable {
    public let id: String
    public let url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }

    public static func detect(
        branch: String?,
        cwd: String,
        environment: [String: String]
    ) -> LinearIssueReference? {
        guard let id = issueID(in: branch) ?? issueID(in: cwd) else {
            return nil
        }
        return LinearIssueReference(id: id, url: issueURL(for: id, environment: environment))
    }

    /// Resolves the issue label shown for a session, preserving explicit
    /// bindings before falling back to title text and repository context.
    public static func preferredID(
        titleURL: String?,
        title: String?,
        branch: String?,
        cwd: String,
        environment: [String: String]
    ) -> String? {
        issueID(in: titleURL)
            ?? issueID(in: title)
            ?? detect(branch: branch, cwd: cwd, environment: environment)?.id
    }

    public static func issueID(in value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"(?i)(?:^|[^A-Z0-9])([A-Z]{2,5}-\d+)(?=$|[^A-Z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range]).uppercased()
    }

    public static func issueURL(for id: String, environment: [String: String]) -> String {
        let baseURL: String
        if let configuredBaseURL = environment["BANYAN_LINEAR_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredBaseURL.isEmpty {
            baseURL = configuredBaseURL
        } else {
            let org = environment["BANYAN_LINEAR_ORG"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            baseURL = "https://linear.app/\((org?.isEmpty == false ? org : nil) ?? "2en")/issue"
        }
        return "\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(id.uppercased())"
    }
}
