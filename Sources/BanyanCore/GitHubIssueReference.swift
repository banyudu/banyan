import Foundation

public struct GitHubIssueReference: Equatable, Sendable {
    public let url: String
    public let number: Int

    public init(url: String, number: Int) {
        self.url = url
        self.number = number
    }

    public static func detect(in value: String?) -> GitHubIssueReference? {
        guard let value else { return nil }
        let pattern = #"https://github\.com/[^\s/]+/[^\s/]+/issues/(\d+)(?=$|[^\d])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let urlRange = Range(match.range, in: value),
              let numberRange = Range(match.range(at: 1), in: value),
              let number = Int(value[numberRange]) else { return nil }
        return GitHubIssueReference(url: String(value[urlRange]), number: number)
    }

    public static func detect(
        branch: String?,
        remoteAddress: String?,
        issueTracker: String? = nil
    ) -> GitHubIssueReference? {
        guard issueTracker != "linear",
              let branch,
              let remoteAddress,
              remoteAddress.hasPrefix("github.com/") else { return nil }
        let repoPath = String(remoteAddress.dropFirst("github.com/".count))
        let pattern = #"(?:^|/)(\d+)-(?=[a-zA-Z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)),
              let numberRange = Range(match.range(at: 1), in: branch),
              let number = Int(branch[numberRange]) else { return nil }
        return GitHubIssueReference(
            url: "https://github.com/\(repoPath)/issues/\(number)",
            number: number
        )
    }

    public static func issueTracker(cwd: String) -> String? {
        let path = (cwd as NSString).appendingPathComponent(".banyan/settings.json")
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(ProjectConfig.self, from: data),
              let tracker = config.issueTracker?.lowercased(),
              ["github", "linear"].contains(tracker) else { return nil }
        return tracker
    }

    private struct ProjectConfig: Decodable {
        let issueTracker: String?
    }
}
