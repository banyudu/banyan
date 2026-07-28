import BanyanCore
import Foundation

struct SessionContextLookupInput: Equatable, Sendable {
    let sessionID: String
    let cwd: String
    let title: String
    let titleURL: String?
    let displayTitle: String

    var signature: String {
        [
            sessionID,
            cwd,
            title,
            titleURL ?? "",
            displayTitle
        ].joined(separator: "\u{1f}")
    }
}

struct SessionContextInfo: Equatable, Sendable {
    let sessionID: String
    let signature: String
    let linearIssueID: String?
    let linearIssueTitle: String?
    let linearIssueURL: String?
    let githubIssueNumber: Int?
    let githubIssueTitle: String?
    let githubIssueURL: String?
    let pullRequestNumber: Int?
    let pullRequestTitle: String?
    let pullRequestURL: String?

    /// Re-stamp a cached result for a new session/signature. The network-derived
    /// fields (linear title, PR) depend only on cwd + issue/PR tokens, so a cache
    /// entry stays valid across signatures that share the same resolver cache key.
    func reidentified(sessionID: String, signature: String) -> SessionContextInfo {
        SessionContextInfo(
            sessionID: sessionID,
            signature: signature,
            linearIssueID: linearIssueID,
            linearIssueTitle: linearIssueTitle,
            linearIssueURL: linearIssueURL,
            githubIssueNumber: githubIssueNumber,
            githubIssueTitle: githubIssueTitle,
            githubIssueURL: githubIssueURL,
            pullRequestNumber: pullRequestNumber,
            pullRequestTitle: pullRequestTitle,
            pullRequestURL: pullRequestURL
        )
    }
}

enum SessionContextResolver {
    static func resolve(
        input: SessionContextLookupInput,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> SessionContextInfo {
        let projectContext = SessionDisplayLabel.context(cwd: input.cwd)
        let remoteAddress = projectContext.groupID.hasPrefix("git:")
            ? String(projectContext.groupID.dropFirst(4))
            : nil
        let tracker = GitHubIssueReference.issueTracker(cwd: input.cwd)
        let githubIssue = tracker == "linear" ? nil : (
            githubIssueReference(in: input)
                ?? GitHubIssueReference.detect(
                    branch: projectContext.branch,
                    remoteAddress: remoteAddress,
                    issueTracker: tracker
                )
        )
        let detectedIssueID: String? = (githubIssue != nil || tracker == "github")
            ? nil
            : (linearIssueID(in: input.title)
                ?? linearIssueID(in: input.titleURL)
                ?? linearIssueID(in: input.displayTitle)
                ?? LinearIssueReference.detect(branch: projectContext.branch, cwd: input.cwd)?.id)
        let resolvedIssueID = detectedIssueID
        let linearURL = resolvedIssueID.map(LinearIssueReference.issueURL(for:))
        let explicitPullRequestURL = pullRequestURL(in: input.titleURL)
            ?? pullRequestURL(in: input.title)
            ?? pullRequestURL(in: input.displayTitle)

        // The `linear issue title` and `gh pr view` lookups are independent network
        // subprocesses. Run them concurrently so a cache-miss resolve costs one CLI
        // round-trip (~timeout) instead of two back-to-back — the sequential form was
        // the dominant term in the selected_context.resolve latency (avg ~2.3s).
        //
        // Both run through SubprocessRunner's async bridge, which suspends this Task
        // during I/O instead of blocking a cooperative thread. The former
        // `DispatchGroup.wait()` here blocked the Swift-concurrency pool and was half
        // of the app-freeze deadlock.
        let cwd = input.cwd
        async let linearTitle: String? = {
            guard let issueID = detectedIssueID, !isCancelled() else { return nil }
            return await commandOutput(
                ["linear", "issue", "title", issueID],
                cwd: cwd,
                timeout: networkTimeout,
                isCancelled: isCancelled
            )
        }()

        async let resolvedPullRequest: PullRequestPayload? = {
            if let explicitPullRequestURL {
                return PullRequestPayload(
                    url: explicitPullRequestURL,
                    title: nil,
                    number: pullRequestNumber(in: explicitPullRequestURL)
                )
            }
            guard !isCancelled() else { return nil }
            return await pullRequest(cwd: cwd, isCancelled: isCancelled)
        }()

        let title = await linearTitle
        let pr = await resolvedPullRequest

        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: resolvedIssueID,
            linearIssueTitle: title,
            linearIssueURL: linearURL,
            githubIssueNumber: githubIssue?.number,
            githubIssueTitle: nil,
            githubIssueURL: githubIssue?.url,
            pullRequestNumber: pr?.number,
            pullRequestTitle: pr?.title,
            pullRequestURL: pr?.url
        )
    }

    /// Best-effort timeout for the network CLIs (`linear`, `gh`). Kept short so a
    /// slow/offline lookup can't stall context resolution; cache absorbs the rest.
    private static let networkTimeout: TimeInterval = 2.5

    /// Pure, subprocess-free resolution: only the issue ID and PR URL that can be
    /// parsed directly from the session title strings. Used to populate the
    /// titlebar instantly while the network/git enrichment runs (or on cache miss).
    static func resolveFast(input: SessionContextLookupInput) -> SessionContextInfo {
        let issueID = titleIssueID(input)
        let explicitPR = titlePullRequestURL(input)
        let tracker = GitHubIssueReference.issueTracker(cwd: input.cwd)
        let githubIssue = tracker == "linear" ? nil : (
            githubIssueReference(in: input)
        )
        let resolvedIssueID = (githubIssue != nil || tracker == "github") ? nil : issueID
        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: resolvedIssueID,
            linearIssueTitle: nil,
            linearIssueURL: resolvedIssueID.map(LinearIssueReference.issueURL(for:)),
            githubIssueNumber: githubIssue?.number,
            githubIssueTitle: nil,
            githubIssueURL: githubIssue?.url,
            pullRequestNumber: explicitPR.flatMap(pullRequestNumber(in:)),
            pullRequestTitle: nil,
            pullRequestURL: explicitPR
        )
    }

    /// Key for the resolve cache. Captures only the inputs that actually change the
    /// network/git result — the working directory and any issue/PR tokens embedded
    /// in the title — so free-text title churn no longer forces a re-resolve.
    static func cacheKey(for input: SessionContextLookupInput) -> String {
        [input.cwd, titleIssueID(input) ?? "", titlePullRequestURL(input) ?? "", titleGitHubIssueURL(input) ?? ""]
            .joined(separator: "\u{1f}")
    }

    private static func titleIssueID(_ input: SessionContextLookupInput) -> String? {
        linearIssueID(in: input.title)
            ?? linearIssueID(in: input.titleURL)
            ?? linearIssueID(in: input.displayTitle)
    }

    private static func linearIssueID(in value: String?) -> String? {
        guard GitHubIssueReference.detect(in: value) == nil else { return nil }
        return LinearIssueReference.issueID(in: value)
    }

    private static func titlePullRequestURL(_ input: SessionContextLookupInput) -> String? {
        pullRequestURL(in: input.titleURL)
            ?? pullRequestURL(in: input.title)
            ?? pullRequestURL(in: input.displayTitle)
    }

    private static func titleGitHubIssueURL(_ input: SessionContextLookupInput) -> String? {
        githubIssueReference(in: input)?.url
    }

    private static func githubIssueReference(in input: SessionContextLookupInput) -> GitHubIssueReference? {
        GitHubIssueReference.detect(in: input.titleURL)
            ?? GitHubIssueReference.detect(in: input.title)
            ?? GitHubIssueReference.detect(in: input.displayTitle)
    }

    private struct PullRequestPayload: Decodable {
        let url: String
        let title: String?
        let number: Int?
    }

    private static func pullRequestURL(in value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"https://github\.com/[^\s/]+/[^\s/]+/pull/\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let matchRange = Range(match.range, in: value) else {
            return nil
        }
        return String(value[matchRange])
    }


    private static func pullRequestNumber(in url: String) -> Int? {
        guard let value = url.split(separator: "/").last else { return nil }
        return Int(value)
    }

    private static func pullRequest(
        cwd: String,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> PullRequestPayload? {
        guard let output = await commandOutput(
            ["gh", "pr", "view", "--json", "url,title,number"],
            cwd: cwd,
            timeout: networkTimeout,
            isCancelled: isCancelled
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(PullRequestPayload.self, from: Data(output.utf8))
    }

    private static func commandOutput(
        _ arguments: [String],
        cwd: String,
        timeout: TimeInterval = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> String? {
        guard let output = try? await SubprocessRunner.runAsync(
            arguments: arguments,
            cwd: cwd,
            environment: processEnvironment(),
            timeout: timeout,
            isCancelled: isCancelled
        ), output.terminationStatus == 0 else {
            return nil
        }
        let text = cleanCommandOutput(String(decoding: output.standardOutput, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func cleanCommandOutput(_ value: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
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
