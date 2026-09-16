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
///
/// Verified answers are remembered in `GitHubReferenceCache`: a resolved URL
/// indefinitely (numbers are never reused), a confirmed miss only briefly.
enum GitHubReferenceResolver {
    static func resolve(
        number: Int,
        cwd: String,
        environment: [String: String],
        homeDirectory: String,
        repositoryGroupID: String? = nil,
        cache: GitHubReferenceCache? = nil
    ) async -> URL? {
        let repository = repositoryGroupID.flatMap(repositoryPath(forGroupID:))

        if let repositoryGroupID, repository != nil, let cache {
            switch cache.outcome(groupID: repositoryGroupID, number: number) {
            case .resolved(let url):
                return url
            case .missing:
                return nil
            case .unknown:
                break
            }
        }

        func remember(_ outcome: GitHubReferenceCache.Outcome) {
            guard let repositoryGroupID, repository != nil else { return }
            cache?.store(outcome, groupID: repositoryGroupID, number: number)
        }

        var pullRequestAbsent = false
        do {
            let url = try await GitHubPullRequestClient.pullRequestURL(
                number: number,
                cwd: cwd,
                environment: environment,
                homeDirectory: homeDirectory
            )
            remember(.resolved(url))
            return url
        } catch {
            pullRequestAbsent = GitHubPullRequestClient.isReferenceNotFound(error)
        }

        var issueAbsent = false
        do {
            let url = try await GitHubIssueClient.issueURL(
                number: number,
                cwd: cwd,
                environment: environment,
                homeDirectory: homeDirectory
            )
            remember(.resolved(url))
            return url
        } catch {
            issueAbsent = GitHubIssueClient.isReferenceNotFound(error)
        }

        if pullRequestAbsent && issueAbsent {
            remember(.missing)
            return nil
        }

        // One of the lookups could not run, so the number may still exist and a
        // URL is worth trying — but it is unverified, so it stays out of the
        // cache. The session already knows its repository in the common case.
        if let repository {
            return URL(string: "https://github.com/\(repository)/issues/\(number)")
        }
        let groupID = SessionDisplayLabel.cachedContext(
            cwd: cwd,
            homeDirectory: homeDirectory,
            environment: environment
        ).groupID
        return repositoryURL(number: number, groupID: groupID)
    }

    /// The repository path for a reference whose `gh` lookups could not answer.
    /// GitHub serves both issues and pull requests under `/issues/<n>`.
    static func repositoryURL(number: Int, groupID: String) -> URL? {
        guard let repository = repositoryPath(forGroupID: groupID) else { return nil }
        return URL(string: "https://github.com/\(repository)/issues/\(number)")
    }

    /// `owner/repo` for a GitHub group id (`git:github.com/...`), or nil when
    /// the session repository is not on GitHub.
    static func repositoryPath(forGroupID groupID: String) -> String? {
        let prefix = "git:github.com/"
        guard groupID.hasPrefix(prefix) else { return nil }
        let repository = String(groupID.dropFirst(prefix.count))
        return repository.isEmpty ? nil : repository
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
