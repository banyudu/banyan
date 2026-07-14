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
            pullRequestNumber: pullRequestNumber,
            pullRequestTitle: pullRequestTitle,
            pullRequestURL: pullRequestURL
        )
    }
}

enum SessionContextResolver {
    static func resolve(input: SessionContextLookupInput, isCancelled: @escaping () -> Bool = { false }) -> SessionContextInfo {
        let projectContext = SessionDisplayLabel.context(cwd: input.cwd)
        let detectedIssueID = LinearIssueReference.issueID(in: input.title)
            ?? LinearIssueReference.issueID(in: input.titleURL)
            ?? LinearIssueReference.issueID(in: input.displayTitle)
            ?? LinearIssueReference.detect(branch: projectContext.branch, cwd: input.cwd)?.id
        let resolvedIssueID = detectedIssueID
        let linearURL = resolvedIssueID.map(LinearIssueReference.issueURL(for:))
        let explicitPullRequestURL = pullRequestURL(in: input.titleURL)
            ?? pullRequestURL(in: input.title)
            ?? pullRequestURL(in: input.displayTitle)

        // The `linear issue title` and `gh pr view` lookups are independent network
        // subprocesses. Run them concurrently so a cache-miss resolve costs one CLI
        // round-trip (~timeout) instead of two back-to-back — the sequential form was
        // the dominant term in the selected_context.resolve latency (avg ~2.3s).
        var linearTitle: String?
        var resolvedPullRequest: PullRequestPayload?
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "banyan.selected-context.resolve", attributes: .concurrent)

        if let issueID = detectedIssueID, !isCancelled() {
            group.enter()
            queue.async {
                linearTitle = commandOutput(
                    ["linear", "issue", "title", issueID],
                    cwd: input.cwd,
                    timeout: networkTimeout,
                    isCancelled: isCancelled
                )
                group.leave()
            }
        }

        if let explicitPullRequestURL {
            resolvedPullRequest = PullRequestPayload(
                url: explicitPullRequestURL,
                title: nil,
                number: pullRequestNumber(in: explicitPullRequestURL)
            )
        } else if !isCancelled() {
            group.enter()
            queue.async {
                resolvedPullRequest = pullRequest(cwd: input.cwd, isCancelled: isCancelled)
                group.leave()
            }
        }

        group.wait()

        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: resolvedIssueID,
            linearIssueTitle: linearTitle,
            linearIssueURL: linearURL,
            pullRequestNumber: resolvedPullRequest?.number,
            pullRequestTitle: resolvedPullRequest?.title,
            pullRequestURL: resolvedPullRequest?.url
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
        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: issueID,
            linearIssueTitle: nil,
            linearIssueURL: issueID.map(LinearIssueReference.issueURL(for:)),
            pullRequestNumber: explicitPR.flatMap(pullRequestNumber(in:)),
            pullRequestTitle: nil,
            pullRequestURL: explicitPR
        )
    }

    /// Key for the resolve cache. Captures only the inputs that actually change the
    /// network/git result — the working directory and any issue/PR tokens embedded
    /// in the title — so free-text title churn no longer forces a re-resolve.
    static func cacheKey(for input: SessionContextLookupInput) -> String {
        [input.cwd, titleIssueID(input) ?? "", titlePullRequestURL(input) ?? ""]
            .joined(separator: "\u{1f}")
    }

    private static func titleIssueID(_ input: SessionContextLookupInput) -> String? {
        LinearIssueReference.issueID(in: input.title)
            ?? LinearIssueReference.issueID(in: input.titleURL)
            ?? LinearIssueReference.issueID(in: input.displayTitle)
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

    private static func pullRequest(cwd: String, isCancelled: @escaping () -> Bool = { false }) -> PullRequestPayload? {
        guard let output = commandOutput(
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
        isCancelled: @escaping () -> Bool = { false }
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = processEnvironment()

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var didExit = false
        while !isCancelled(), Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            let waitTime = min(0.1, max(0, remaining))
            if semaphore.wait(timeout: .now() + waitTime) == .success {
                didExit = true
                break
            }
        }

        guard didExit else {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
            .map(cleanCommandOutput)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
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
