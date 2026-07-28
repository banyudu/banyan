import BanyanCore
import Foundation

struct GitHubIssueDetails: Equatable, Identifiable {
    var id: String { url }
    let url: String
    let number: Int
    let title: String
    let body: String?
    let state: String?
    let authorLogin: String?
    let labels: [String]
    let assignees: [String]
    let milestone: String?
    let comments: [GitHubIssueComment]
    let createdAt: String?
    let updatedAt: String?
}

struct GitHubIssueComment: Equatable, Identifiable {
    let id: String
    let body: String
    let authorLogin: String?
    let createdAt: String?
}

enum GitHubIssueLoadState: Equatable { case idle, loading, loaded, failed(String) }

enum GitHubIssueClient {
    static func decodeDetails(_ data: Data) throws -> GitHubIssueDetails {
        try JSONDecoder().decode(Payload.self, from: data).details
    }

    static func fetchIssue(
        url: URL,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> GitHubIssueDetails {
        let fields = "author,body,comments,createdAt,labels,assignees,milestone,number,state,title,updatedAt,url"
        let output = try await SubprocessRunner.runAsync(
            arguments: ["gh", "issue", "view", url.absoluteString, "--json", fields],
            cwd: cwd,
            environment: processEnvironment(base: environment, homeDirectory: homeDirectory),
            timeout: 12
        )
        guard output.terminationStatus == 0 else {
            throw GitHubIssueClientError.requestFailed
        }
        return try decodeDetails(output.standardOutput)
    }

    static func message(for error: Error) -> String {
        if let error = error as? GitHubIssueClientError, error == .requestFailed {
            return "gh issue view failed"
        }
        if let error = error as? SubprocessRunner.RunError, case .timedOut = error {
            return "gh issue view timed out"
        }
        return "Unable to load GitHub issue"
    }

    private static func processEnvironment(
        base: [String: String],
        homeDirectory: String
    ) -> [String: String] {
        AppProcessEnvironment.make(base: base, shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: base), pathAdditions: [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"
        ], overrides: [
            "CLICOLOR": "0", "CLICOLOR_FORCE": "0", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"
        ])
    }
}

private enum GitHubIssueClientError: Error, Equatable { case requestFailed }

private struct Payload: Decodable {
    let url: String
    let number: Int
    let title: String
    let body: String?
    let state: String?
    let author: User?
    let labels: [Label]?
    let assignees: [User]?
    let milestone: Milestone?
    let comments: [Comment]?
    let createdAt: String?
    let updatedAt: String?

    var details: GitHubIssueDetails {
        GitHubIssueDetails(url: url, number: number, title: title, body: body, state: state,
            authorLogin: author?.login, labels: (labels ?? []).map(\.name),
            assignees: (assignees ?? []).compactMap(\.login), milestone: milestone?.title,
            comments: (comments ?? []).map(\.details), createdAt: createdAt, updatedAt: updatedAt)
    }
}
private struct User: Decodable { let login: String? }
private struct Label: Decodable { let name: String }
private struct Milestone: Decodable { let title: String? }
private struct Comment: Decodable {
    let id: Int?
    let body: String?
    let author: User?
    let createdAt: String?
    var details: GitHubIssueComment { GitHubIssueComment(id: String(id ?? 0), body: body ?? "", authorLogin: author?.login, createdAt: createdAt) }
}
