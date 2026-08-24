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
    static var axiomExporter: AxiomExporter?

    static func pullRequestURL(
        number: Int,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> URL {
        let start = DispatchTime.now()
        do {
            let output = try await runCommand(
                ["gh", "pr", "view", String(number), "--json", "url"],
                cwd: cwd,
                timeout: 12,
                environment: environment,
                homeDirectory: homeDirectory
            )
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            axiomExporter?.sendHTTPRequest(
                service: "github",
                method: "CLI",
                url: "github-cli://gh/pr/view#url",
                statusCode: 200,
                durationMS: duration
            )
            let payload = try JSONDecoder().decode(GitHubPullRequestReferencePayload.self, from: Data(output.utf8))
            guard let rawURL = payload.url, let url = URL(string: rawURL) else {
                throw GitHubPullRequestClientError.requestFailed("No URL found for pull request #\(number)")
            }
            return url
        } catch {
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            axiomExporter?.sendHTTPRequest(
                service: "github",
                method: "CLI",
                url: "github-cli://gh/pr/view#url",
                statusCode: error is GitHubPullRequestClientError ? 500 : 0,
                durationMS: duration,
                error: error.localizedDescription
            )
            throw error
        }
    }

    static func fetchPullRequest(
        url: URL?,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> GitHubPullRequestDetails {
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
            output = try await pullRequestOutput(url: url, fields: fields, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
        } catch {
            guard url == nil,
                  let resolvedURL = try? await resolvePullRequestURL(cwd: cwd, environment: environment, homeDirectory: homeDirectory) else {
                throw error
            }
            output = try await pullRequestOutput(url: resolvedURL, fields: fields, cwd: cwd, environment: environment, homeDirectory: homeDirectory)
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

    private static func pullRequestOutput(
        url: URL?,
        fields: String,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> String {
        var arguments = ["gh", "pr", "view"]
        if let url {
            arguments.append(url.absoluteString)
        }
        arguments += ["--json", fields]

        let start = DispatchTime.now()
        do {
            let output = try await runCommand(arguments, cwd: cwd, timeout: 12, environment: environment, homeDirectory: homeDirectory)
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            axiomExporter?.sendHTTPRequest(
                service: "github",
                method: "CLI",
                url: url == nil ? "github-cli://gh/pr/view#current" : "github-cli://gh/pr/view",
                statusCode: 200,
                durationMS: duration
            )
            return output
        } catch {
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            axiomExporter?.sendHTTPRequest(
                service: "github",
                method: "CLI",
                url: url == nil ? "github-cli://gh/pr/view#current" : "github-cli://gh/pr/view",
                statusCode: 0,
                durationMS: duration,
                error: error.localizedDescription
            )
            throw error
        }
    }

    private static func resolvePullRequestURL(
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> URL {
        let branch = try await currentBranch(cwd: cwd, environment: environment, homeDirectory: homeDirectory)
        guard await !isDefaultBranch(branch, cwd: cwd, environment: environment, homeDirectory: homeDirectory) else {
            throw GitHubPullRequestClientError.requestFailed("No GitHub pull request found for branch \(branch)")
        }

        let start = DispatchTime.now()
        do {
            let output = try await runCommand(
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
                timeout: 12,
                environment: environment,
                homeDirectory: homeDirectory
            )
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            axiomExporter?.sendHTTPRequest(
                service: "github",
                method: "CLI",
                url: "github-cli://gh/pr/list",
                statusCode: 200,
                durationMS: duration
            )
            let payload = try JSONDecoder().decode([GitHubPullRequestReferencePayload].self, from: Data(output.utf8))
            guard let rawURL = payload.first?.url,
                  let url = URL(string: rawURL) else {
                throw GitHubPullRequestClientError.requestFailed("No GitHub pull request found for branch \(branch)")
            }
            return url
        } catch {
            let duration = PerformanceTelemetry.elapsedMS(since: start)
            // Only emit if not already a GitHubPullRequestClientError with dedicated handling above; but this catch includes decode failures too
            if (error as? GitHubPullRequestClientError) == nil {
                axiomExporter?.sendHTTPRequest(
                    service: "github",
                    method: "CLI",
                    url: "github-cli://gh/pr/list",
                    statusCode: 0,
                    durationMS: duration,
                    error: error.localizedDescription
                )
            } else {
                axiomExporter?.sendHTTPRequest(
                    service: "github",
                    method: "CLI",
                    url: "github-cli://gh/pr/list",
                    statusCode: 500,
                    durationMS: duration,
                    error: error.localizedDescription
                )
            }
            throw error
        }
    }

    private static func currentBranch(
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> String {
        if let branch = try? await runCommand(["git", "branch", "--show-current"], cwd: cwd, timeout: 4, environment: environment, homeDirectory: homeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !branch.isEmpty {
            return branch
        }

        let fallback = try await runCommand(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd, timeout: 4, environment: environment, homeDirectory: homeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty, fallback != "HEAD" else {
            throw GitHubPullRequestClientError.requestFailed("No current git branch found")
        }
        return fallback
    }

    private static func isDefaultBranch(
        _ branch: String,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async -> Bool {
        if branch == "main" || branch == "master" {
            return true
        }

        guard let remoteHead = try? await runCommand(
            ["git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd,
            timeout: 4,
            environment: environment,
            homeDirectory: homeDirectory
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
        timeout: TimeInterval,
        environment: [String: String],
        homeDirectory: String
    ) async throws -> String {
        let output: SubprocessRunner.Output
        do {
            output = try await SubprocessRunner.runAsync(
                arguments: arguments,
                cwd: cwd,
                environment: processEnvironment(
                    base: environment,
                    homeDirectory: homeDirectory,
                    shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: environment)
                ),
                timeout: timeout
            )
        } catch SubprocessRunner.RunError.launchFailed(_) {
            throw GitHubPullRequestClientError.commandUnavailable
        } catch SubprocessRunner.RunError.timedOut {
            throw GitHubPullRequestClientError.timedOut
        } catch SubprocessRunner.RunError.cancelled {
            throw GitHubPullRequestClientError.requestFailed("cancelled")
        } catch {
            throw GitHubPullRequestClientError.requestFailed(error.localizedDescription)
        }

        guard output.terminationStatus == 0 else {
            let message = String(data: output.standardError, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Also try stdout for gh error messages
            let stdoutMessage = String(data: output.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let combined = [message, stdoutMessage].compactMap { $0 }.first { !$0.isEmpty }
            throw GitHubPullRequestClientError.requestFailed(combined)
        }

        guard let raw = String(data: output.standardOutput, encoding: .utf8)?
            .cleanedGitHubCLIOutput()
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            throw GitHubPullRequestClientError.requestFailed(nil)
        }
        return raw
    }

    private static func processEnvironment(
        base: [String: String],
        homeDirectory: String,
        shellEnvironment: [String: String]
    ) -> [String: String] {
        let additions = [
            "\(homeDirectory)/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.cargo/bin",
            "\(homeDirectory)/go/bin",
            "\(homeDirectory)/.nix-profile/bin",
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
