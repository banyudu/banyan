import Foundation

struct GitHubPullRequestDetails: Equatable, Identifiable {
    var id: String { url }
    let url: String
    let number: Int?
    let title: String
    let state: String?
    let isDraft: Bool
    let authorLogin: String?
    let baseRefName: String?
    let headRefName: String?
    let body: String?
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let comments: [GitHubPullRequestComment]
    let reviews: [GitHubPullRequestReview]
}

struct GitHubPullRequestComment: Equatable, Identifiable {
    let id: String
    let body: String
    let createdAt: String?
    let authorLogin: String?
}

struct GitHubPullRequestReview: Equatable, Identifiable {
    let id: String
    let body: String?
    let state: String?
    let submittedAt: String?
    let authorLogin: String?
}

enum GitHubPullRequestLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum GitHubPullRequestClient {
    static func fetchPullRequest(url: URL?, cwd: String) async throws -> GitHubPullRequestDetails {
        let fields = [
            "additions",
            "author",
            "baseRefName",
            "body",
            "changedFiles",
            "comments",
            "deletions",
            "headRefName",
            "isDraft",
            "mergeStateStatus",
            "mergeable",
            "number",
            "reviewDecision",
            "reviews",
            "state",
            "title",
            "url"
        ].joined(separator: ",")

        var arguments = ["gh", "pr", "view"]
        if let url {
            arguments.append(url.absoluteString)
        }
        arguments += ["--json", fields]

        let output = try await Task.detached(priority: .utility) {
            try runCommand(arguments, cwd: cwd, timeout: 12)
        }.value
        let payload = try JSONDecoder().decode(GitHubPullRequestPayload.self, from: Data(output.utf8))
        return payload.details
    }

    private static func runCommand(
        _ arguments: [String],
        cwd: String,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = processEnvironment()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw GitHubPullRequestClientError.commandUnavailable
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            throw GitHubPullRequestClientError.timedOut
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitHubPullRequestClientError.requestFailed(message)
        }

        guard let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            throw GitHubPullRequestClientError.requestFailed(nil)
        }
        return output
    }

    private static func processEnvironment() -> [String: String] {
        let additions = [
            "\(NSHomeDirectory())/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/go/bin",
            "\(NSHomeDirectory())/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        return AppProcessEnvironment.make(pathAdditions: additions)
    }
}

private enum GitHubPullRequestClientError: Error {
    case commandUnavailable
    case timedOut
    case requestFailed(String?)
}

private struct GitHubPullRequestPayload: Decodable {
    let url: String
    let number: Int?
    let title: String?
    let state: String?
    let isDraft: Bool?
    let author: GitHubUserPayload?
    let baseRefName: String?
    let headRefName: String?
    let body: String?
    let reviewDecision: String?
    let mergeable: String?
    let mergeStateStatus: String?
    let additions: Int?
    let deletions: Int?
    let changedFiles: Int?
    let comments: [GitHubPullRequestCommentPayload]?
    let reviews: [GitHubPullRequestReviewPayload]?

    var details: GitHubPullRequestDetails {
        GitHubPullRequestDetails(
            url: url,
            number: number,
            title: title ?? "Pull Request",
            state: state,
            isDraft: isDraft ?? false,
            authorLogin: author?.login,
            baseRefName: baseRefName,
            headRefName: headRefName,
            body: body,
            reviewDecision: reviewDecision,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            additions: additions,
            deletions: deletions,
            changedFiles: changedFiles,
            comments: (comments ?? []).map(\.comment),
            reviews: (reviews ?? []).map(\.review)
        )
    }
}

private struct GitHubUserPayload: Decodable {
    let login: String?
}

private struct GitHubPullRequestCommentPayload: Decodable {
    let id: String?
    let body: String?
    let createdAt: String?
    let author: GitHubUserPayload?

    var comment: GitHubPullRequestComment {
        GitHubPullRequestComment(
            id: id ?? UUID().uuidString,
            body: body ?? "",
            createdAt: createdAt,
            authorLogin: author?.login
        )
    }
}

private struct GitHubPullRequestReviewPayload: Decodable {
    let id: String?
    let body: String?
    let state: String?
    let submittedAt: String?
    let author: GitHubUserPayload?

    var review: GitHubPullRequestReview {
        GitHubPullRequestReview(
            id: id ?? UUID().uuidString,
            body: body,
            state: state,
            submittedAt: submittedAt,
            authorLogin: author?.login
        )
    }
}
