import Foundation

public struct SessionContextLookupInput: Equatable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let homeDirectory: String
    public let environment: [String: String]
    public let title: String
    public let titleURL: String?
    public let displayTitle: String

    public init(
        sessionID: String,
        cwd: String,
        homeDirectory: String,
        environment: [String: String],
        title: String,
        titleURL: String?,
        displayTitle: String
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.homeDirectory = homeDirectory
        self.environment = environment
        self.title = title
        self.titleURL = titleURL
        self.displayTitle = displayTitle
    }

    public var signature: String {
        [
            sessionID,
            cwd,
            homeDirectory,
            environment["BANYAN_LINEAR_BASE_URL"] ?? "",
            environment["BANYAN_LINEAR_ORG"] ?? "",
            title,
            titleURL ?? "",
            displayTitle
        ].joined(separator: "\u{1f}")
    }
}

public struct SessionContextInfo: Equatable, Sendable {
    public let sessionID: String
    public let signature: String
    public let linearIssueID: String?
    public let linearIssueTitle: String?
    public let linearIssueURL: String?
    public let githubIssueNumber: Int?
    public let githubIssueTitle: String?
    public let githubIssueURL: String?
    public let pullRequestNumber: Int?
    public let pullRequestTitle: String?
    public let pullRequestURL: String?

    public init(
        sessionID: String,
        signature: String,
        linearIssueID: String?,
        linearIssueTitle: String?,
        linearIssueURL: String?,
        githubIssueNumber: Int?,
        githubIssueTitle: String?,
        githubIssueURL: String?,
        pullRequestNumber: Int?,
        pullRequestTitle: String?,
        pullRequestURL: String?
    ) {
        self.sessionID = sessionID
        self.signature = signature
        self.linearIssueID = linearIssueID
        self.linearIssueTitle = linearIssueTitle
        self.linearIssueURL = linearIssueURL
        self.githubIssueNumber = githubIssueNumber
        self.githubIssueTitle = githubIssueTitle
        self.githubIssueURL = githubIssueURL
        self.pullRequestNumber = pullRequestNumber
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestURL = pullRequestURL
    }

    /// Re-stamp a cached result for a new session/signature. The network-derived
    /// fields (linear title, PR) depend only on cwd + issue/PR tokens, so a cache
    /// entry stays valid across signatures that share the same resolver cache key.
    public func reidentified(sessionID: String, signature: String) -> SessionContextInfo {
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

public enum SessionContextResolver {
    public static func resolve(
        input: SessionContextLookupInput,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> SessionContextInfo {
        let projectContext = SessionDisplayLabel.context(
            cwd: input.cwd,
            homeDirectory: input.homeDirectory,
            environment: input.environment
        )
        let remoteAddress = projectContext.groupID.hasPrefix("git:") ? String(projectContext.groupID.dropFirst(4)) : nil
        let tracker = GitHubIssueReference.issueTracker(cwd: input.cwd)
        let githubIssue = tracker == "linear" ? nil : (githubIssueReference(in: input)
            ?? GitHubIssueReference.detect(branch: projectContext.branch, remoteAddress: remoteAddress, issueTracker: tracker))
        let detectedIssueID: String? = (githubIssue != nil || tracker == "github") ? nil
            : (LinearIssueReference.issueID(in: input.title)
            ?? LinearIssueReference.issueID(in: input.titleURL)
            ?? LinearIssueReference.issueID(in: input.displayTitle)
            ?? LinearIssueReference.detect(
                branch: projectContext.branch,
                cwd: input.cwd,
                environment: input.environment
            )?.id)
        let resolvedIssueID = detectedIssueID
        let linearURL = resolvedIssueID.map {
            LinearIssueReference.issueURL(for: $0, environment: input.environment)
        }
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
        let commandEnvironment = processEnvironment(
            base: input.environment,
            homeDirectory: input.homeDirectory
        )
        async let linearTitle: String? = {
            guard let issueID = detectedIssueID, !isCancelled() else { return nil }
            return await commandOutput(
                ["linear", "issue", "title", issueID],
                cwd: cwd,
                environment: commandEnvironment,
                timeout: networkTimeout,
                isCancelled: isCancelled
            )
        }()

        async let githubTitle: String? = {
            guard let githubIssue, !isCancelled() else { return nil }
            return await commandOutput(
                ["gh", "issue", "view", githubIssue.url, "--json", "title"],
                cwd: cwd,
                environment: commandEnvironment,
                timeout: networkTimeout,
                isCancelled: isCancelled
            )
                .flatMap { try? JSONDecoder().decode(GitHubIssueTitlePayload.self, from: Data($0.utf8)).title }
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
            return await pullRequest(
                cwd: cwd,
                environment: commandEnvironment,
                isCancelled: isCancelled
            )
        }()

        let title = await linearTitle
        let githubTitleValue = await githubTitle
        let pr = await resolvedPullRequest

        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: resolvedIssueID,
            linearIssueTitle: title,
            linearIssueURL: linearURL,
            githubIssueNumber: githubIssue?.number,
            githubIssueTitle: githubTitleValue,
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
    public static func resolveFast(input: SessionContextLookupInput) -> SessionContextInfo {
        let tracker = GitHubIssueReference.issueTracker(cwd: input.cwd)
        let issueID = tracker == "github" ? nil : titleIssueID(input)
        let githubIssue = tracker == "linear" ? nil : githubIssueReference(in: input)
        let explicitPR = titlePullRequestURL(input)
        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: issueID,
            linearIssueTitle: nil,
            linearIssueURL: issueID.map {
                LinearIssueReference.issueURL(for: $0, environment: input.environment)
            },
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
    public static func cacheKey(for input: SessionContextLookupInput) -> String {
        [input.cwd, titleIssueID(input) ?? "", titleGitHubIssueURL(input) ?? "", titlePullRequestURL(input) ?? ""]
            .joined(separator: "\u{1f}")
    }

    private static func titleIssueID(_ input: SessionContextLookupInput) -> String? {
        guard githubIssueReference(in: input) == nil else { return nil }
        return LinearIssueReference.issueID(in: input.title)
            ?? LinearIssueReference.issueID(in: input.titleURL)
            ?? LinearIssueReference.issueID(in: input.displayTitle)
    }

    private static func titleGitHubIssueURL(_ input: SessionContextLookupInput) -> String? {
        githubIssueReference(in: input)?.url
    }

    private static func githubIssueReference(in input: SessionContextLookupInput) -> GitHubIssueReference? {
        GitHubIssueReference.detect(in: input.titleURL)
            ?? GitHubIssueReference.detect(in: input.title)
            ?? GitHubIssueReference.detect(in: input.displayTitle)
    }

    private static func titlePullRequestURL(_ input: SessionContextLookupInput) -> String? {
        pullRequestURL(in: input.titleURL)
            ?? pullRequestURL(in: input.title)
            ?? pullRequestURL(in: input.displayTitle)
    }

    private struct PullRequestPayload: Decodable {
        let url: String
        let title: String?
        let number: Int?
    }

    private struct GitHubIssueTitlePayload: Decodable { let title: String? }

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
        environment: [String: String],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> PullRequestPayload? {
        guard let output = await commandOutput(
            ["gh", "pr", "view", "--json", "url,title,number"],
            cwd: cwd,
            environment: environment,
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
        environment: [String: String],
        timeout: TimeInterval = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> String? {
        guard let output = try? await SubprocessRunner.runAsync(
            arguments: arguments,
            cwd: cwd,
            environment: environment,
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

    private static func processEnvironment(
        base: [String: String],
        homeDirectory: String
    ) -> [String: String] {
        let additions = HostExecutablePaths.userPaths(homeDirectory: homeDirectory)
            + ["/nix/var/nix/profiles/default/bin"]
            + HostExecutablePaths.systemPaths()
        return AppProcessEnvironment.make(
            base: base,
            shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: base),
            pathAdditions: additions
        )
    }

}
