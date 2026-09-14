import BanyanCore
import Foundation

/// Resolves a bare `#123` terminal reference to a GitHub page.
///
/// The number alone carries no repository identity, so lookups run against the
/// session repository through `gh`. When `gh` cannot run at all (missing
/// binary, timeout, auth or network failure), the repository's `/issues/<n>`
/// path is the best available guess: GitHub redirects it to `/pull/<n>` when
/// the number is a pull request. When `gh` *did* run and reported that the
/// repository has no such number, there is nothing to open — a guessed URL
/// would only land on GitHub's 404 page.
enum GitHubReferenceResolver {
    static func resolve(
        number: Int,
        cwd: String,
        environment: [String: String],
        homeDirectory: String
    ) async -> URL? {
        var pullRequestAbsent = false
        do {
            return try await GitHubPullRequestClient.pullRequestURL(
                number: number,
                cwd: cwd,
                environment: environment,
                homeDirectory: homeDirectory
            )
        } catch {
            pullRequestAbsent = GitHubPullRequestClient.isReferenceNotFound(error)
        }

        var issueAbsent = false
        do {
            return try await GitHubIssueClient.issueURL(
                number: number,
                cwd: cwd,
                environment: environment,
                homeDirectory: homeDirectory
            )
        } catch {
            issueAbsent = GitHubIssueClient.isReferenceNotFound(error)
        }

        guard !pullRequestAbsent || !issueAbsent else { return nil }

        let groupID = SessionDisplayLabel.context(
            cwd: cwd,
            homeDirectory: homeDirectory,
            environment: environment
        ).groupID
        return repositoryURL(number: number, groupID: groupID)
    }

    /// The repository path for a reference whose `gh` lookups could not answer.
    /// GitHub serves both issues and pull requests under `/issues/<n>`.
    static func repositoryURL(number: Int, groupID: String) -> URL? {
        let prefix = "git:github.com/"
        guard groupID.hasPrefix(prefix) else { return nil }
        let repository = groupID.dropFirst(prefix.count)
        guard !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/issues/\(number)")
    }

    /// True when `gh` ran and answered that the repository has no issue or
    /// pull request with that number, as opposed to failing to answer at all.
    /// Both clients' `gh pr view` / `gh issue view` errors carry the CLI
    /// message, and the GraphQL miss is phrased "Could not resolve to a ...".
    static func isNotFound(message: String?) -> Bool {
        guard let message else { return false }
        return message.localizedCaseInsensitiveContains("could not resolve to a")
    }
}
