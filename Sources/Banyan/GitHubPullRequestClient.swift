import BanyanCore
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
    static func pullRequestURL(number: Int, cwd: String) async throws -> URL {
        let output = try await Task.detached(priority: .utility) {
            try runCommand(
                ["gh", "pr", "view", String(number), "--json", "url"],
                cwd: cwd,
                timeout: 12
            )
        }.value
        let payload = try JSONDecoder().decode(GitHubPullRequestReferencePayload.self, from: Data(output.utf8))
        guard let rawURL = payload.url, let url = URL(string: rawURL) else {
            throw GitHubPullRequestClientError.requestFailed("No URL found for pull request #\(number)")
        }
        return url
    }

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

        let output: String
        do {
            output = try await pullRequestOutput(url: url, fields: fields, cwd: cwd)
        } catch {
            guard url == nil,
                  let resolvedURL = try? await resolvePullRequestURL(cwd: cwd) else {
                throw error
            }
            output = try await pullRequestOutput(url: resolvedURL, fields: fields, cwd: cwd)
        }

        let payload = try JSONDecoder().decode(GitHubPullRequestPayload.self, from: Data(output.utf8))
        return payload.details
    }

    static func message(for error: Error) -> String {
        guard let error = error as? GitHubPullRequestClientError else {
            return "Unable to load pull request"
        }
        switch error {
        case .commandUnavailable:
            return "Unable to find gh CLI"
        case .timedOut:
            return "gh pr view timed out"
        case let .requestFailed(message):
            return message?.isEmpty == false ? message! : "gh pr view failed"
        }
    }

    private static func pullRequestOutput(url: URL?, fields: String, cwd: String) async throws -> String {
        var arguments = ["gh", "pr", "view"]
        if let url {
            arguments.append(url.absoluteString)
        }
        arguments += ["--json", fields]

        return try await Task.detached(priority: .utility) {
            try runCommand(arguments, cwd: cwd, timeout: 12)
        }.value
    }

    private static func resolvePullRequestURL(cwd: String) async throws -> URL {
        let branch = try await Task.detached(priority: .utility) {
            try currentBranch(cwd: cwd)
        }.value
        guard !isDefaultBranch(branch, cwd: cwd) else {
            throw GitHubPullRequestClientError.requestFailed("No GitHub pull request found for branch \(branch)")
        }

        let output = try await Task.detached(priority: .utility) {
            try runCommand(
                [
                    "gh",
                    "pr",
                    "list",
                    "--head",
                    branch,
                    "--state",
                    "all",
                    "--limit",
                    "1",
                    "--json",
                    "url"
                ],
                cwd: cwd,
                timeout: 12
            )
        }.value
        let payload = try JSONDecoder().decode([GitHubPullRequestReferencePayload].self, from: Data(output.utf8))
        guard let rawURL = payload.first?.url,
              let url = URL(string: rawURL) else {
            throw GitHubPullRequestClientError.requestFailed("No GitHub pull request found for branch \(branch)")
        }
        return url
    }

    private static func currentBranch(cwd: String) throws -> String {
        if let branch = try? runCommand(["git", "branch", "--show-current"], cwd: cwd, timeout: 4)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !branch.isEmpty {
            return branch
        }

        let fallback = try runCommand(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd, timeout: 4)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback != "HEAD" else {
            throw GitHubPullRequestClientError.requestFailed("No current git branch found")
        }
        return fallback
    }

    private static func isDefaultBranch(_ branch: String, cwd: String) -> Bool {
        if branch == "main" || branch == "master" {
            return true
        }

        guard let remoteHead = try? runCommand(
            ["git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd,
            timeout: 4
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        return remoteHead.split(separator: "/").last.map(String.init) == branch
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
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        process.environment = processEnvironment(
            base: inheritedEnvironment,
            homeDirectory: NSHomeDirectory(),
            shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: inheritedEnvironment)
        )

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
            .cleanedGitHubCLIOutput()
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !output.isEmpty else {
            throw GitHubPullRequestClientError.requestFailed(nil)
        }
        return output
    }

    private static func processEnvironment(
        base: [String: String],
        homeDirectory: String,
        shellEnvironment: [String: String]
    ) -> [String: String] {
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
        return AppProcessEnvironment.make(
            base: base,
            shellEnvironment: shellEnvironment,
            pathAdditions: additions,
            overrides: [
                "CLICOLOR": "0",
                "CLICOLOR_FORCE": "0",
                "GH_NO_UPDATE_NOTIFIER": "1",
                "NO_COLOR": "1"
            ]
        )
    }
}

private extension String {
    func cleanedGitHubCLIOutput() -> String {
        replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }
}

private enum GitHubPullRequestClientError: Error {
    case commandUnavailable
    case timedOut
    case requestFailed(String?)
}

private struct GitHubPullRequestReferencePayload: Decodable {
    let url: String?
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
