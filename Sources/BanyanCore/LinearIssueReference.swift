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
        if let branch, !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let id = issueID(in: branch) {
                return LinearIssueReference(id: id, url: issueURL(for: id, environment: environment))
            }
            // Detached HEAD yields a short SHA (e.g. "a1b2c3d") – fall back to cwd
            // so a worktree directory like ".../yudu-ENG-1234" still resolves.
            // A real branch name like "main" or "feature/x" with no issue is an
            // explicit "no issue" signal and should not fall back to a stale cwd.
            let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
            let isSHA = trimmed.range(of: "^[0-9a-f]{7,40}$", options: [.regularExpression, .caseInsensitive]) != nil
            if isSHA {
                guard let id = issueID(in: cwd) else { return nil }
                return LinearIssueReference(id: id, url: issueURL(for: id, environment: environment))
            }
            return nil
        }
        guard let id = issueID(in: cwd) else {
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

    /// Compiled once: `issueID(in:)` runs up to four times per session row via
    /// `preferredID`, and the sidebar evaluates every row, so compiling this per call
    /// cost tens of thousands of ICU regex compilations per sidebar refresh.
    private static let issueIDRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:^|[^A-Z0-9])([A-Z]{2,5}-\d+)(?=$|[^A-Z0-9])"#
    )

    public static func issueID(in value: String?) -> String? {
        guard let value else { return nil }
        guard let match = issueIDRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
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
