import Foundation

public struct SessionProjectContext: Equatable {
    public let project: String
    public let branch: String?
    public let groupID: String
    public let groupTitle: String
    public let isGitWorktree: Bool
    public let isDefaultBranch: Bool
    /// `true` when at least one git lookup feeding `branch` / `isGitWorktree` /
    /// `isDefaultBranch` failed to *run* (timed out or couldn't launch) rather
    /// than running and answering. Those three fields are then unreliable
    /// false-negatives, so callers must not cache this result over a previously
    /// good one — see `BanyanSession.updateDisplayContext`.
    public let gitLookupDegraded: Bool
}

public enum SessionDisplayLabel {
    public static func context(cwd: String) -> SessionProjectContext {
        let resolvedCWD = standardizedPath(cwd)
        let topLevel = gitLookup(["rev-parse", "--show-toplevel"], cwd: resolvedCWD)
        guard let gitTopLevel = topLevel.value else {
            // No top level either means "not a git repo" (a trustworthy answer)
            // or the lookup failed to run — propagate `degraded` so a transient
            // failure isn't cached as "not a worktree".
            let project = projectName(resolvedCWD)
            return SessionProjectContext(
                project: project,
                branch: nil,
                groupID: "path:\(resolvedCWD)",
                groupTitle: project,
                isGitWorktree: false,
                isDefaultBranch: false,
                gitLookupDegraded: topLevel.degraded
            )
        }

        var degraded = false
        let project = projectName(gitTopLevel)

        let symbolic = gitLookup(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: resolvedCWD)
        let symbolicBranch = symbolic.value
        degraded = degraded || symbolic.degraded

        let branch: String?
        if let symbolicBranch {
            branch = symbolicBranch
        } else {
            let shortSHA = gitLookup(["rev-parse", "--short", "HEAD"], cwd: resolvedCWD)
            branch = shortSHA.value
            degraded = degraded || shortSHA.degraded
        }

        let mainDirectory = gitMainDirectory(cwd: resolvedCWD, fallbackTopLevel: gitTopLevel)
        degraded = degraded || mainDirectory.degraded
        let isGitWorktree = standardizedPath(mainDirectory.value) != standardizedPath(gitTopLevel)

        let defaultBranch = symbolicBranch.map { Self.isDefaultBranch($0, cwd: resolvedCWD) } ?? (value: false, degraded: false)
        degraded = degraded || defaultBranch.degraded

        let remote = gitRemoteURL(cwd: resolvedCWD)
        degraded = degraded || remote.degraded
        if let remoteURL = remote.value {
            let normalizedAddress = normalizedGitAddress(remoteURL)
            return SessionProjectContext(
                project: project,
                branch: branch,
                groupID: "git:\(normalizedAddress)",
                groupTitle: gitAddressTitle(normalizedAddress),
                isGitWorktree: isGitWorktree,
                isDefaultBranch: defaultBranch.value,
                gitLookupDegraded: degraded
            )
        }

        return SessionProjectContext(
            project: project,
            branch: branch,
            groupID: "path:\(mainDirectory.value)",
            groupTitle: projectName(mainDirectory.value),
            isGitWorktree: isGitWorktree,
            isDefaultBranch: defaultBranch.value,
            gitLookupDegraded: degraded
        )
    }

    public static func make(
        project: String,
        branch: String?,
        title: String,
        id: String,
        command: String,
        reportedTitle: String? = nil,
        prefersReportedTitle: Bool = false
    ) -> String {
        var components = [clean(project)]
        if let branch = branch.map(clean), !branch.isEmpty {
            components.append(branch)
        }
        let task = taskTitle(
            title: title,
            id: id,
            command: command,
            reportedTitle: reportedTitle,
            prefersReportedTitle: prefersReportedTitle
        )
        components.append("\"\(truncate(task, limit: 44))\"")
        return components.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func taskTitle(
        title: String,
        id: String,
        command: String,
        reportedTitle: String?,
        prefersReportedTitle: Bool
    ) -> String {
        if prefersReportedTitle,
           let reported = reportedTitle.map(clean),
           SessionTitleGenerator.isUsefulTitle(reported) {
            return reported
        }

        let cleanedTitle = clean(title)
        if !SessionTitleGenerator.isGenericTitle(cleanedTitle),
           !SessionTitleGenerator.looksLikeHostTitle(cleanedTitle) {
            return cleanedTitle
        }

        let cleanedCommand = clean(command)
        if !cleanedCommand.isEmpty {
            return prettyCommand(cleanedCommand)
        }

        let cleanedID = clean(id)
        if !SessionTitleGenerator.isGenericTitle(cleanedID),
           !SessionTitleGenerator.looksLikeHostTitle(cleanedID) {
            return cleanedID
        }

        return "shell"
    }

    private static func prettyCommand(_ command: String) -> String {
        let shellNames = ["bash", "fish", "sh", "zsh"]
        if shellNames.contains(command) || shellNames.contains(URL(fileURLWithPath: command).lastPathComponent) {
            return "shell"
        }

        if let provider = CodingAgentProvider.detect(in: command) {
            if let prompt = CodingAgentProvider.promptCandidate(in: command, provider: provider),
               let title = SessionTitleGenerator.titleFromPrompt(prompt) {
                return title
            }
            return provider.displayName
        }

        return command
    }

    private static func clean(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 3))
        return "\(value[..<end])..."
    }

    private static func projectName(_ path: String) -> String {
        let canonicalPath = standardizedPath(path)
        let homePath = PathDisplayName.canonicalPath(NSHomeDirectory())
        if canonicalPath == homePath || canonicalPath.hasPrefix(homePath + "/") {
            return PathDisplayName.make(path: canonicalPath, homeDirectory: NSHomeDirectory())
        }

        let url = URL(fileURLWithPath: canonicalPath).standardizedFileURL
        let component = url.lastPathComponent
        return component.isEmpty ? url.path : component
    }

    private static func standardizedPath(_ path: String) -> String {
        PathDisplayName.canonicalPath(path)
    }

    private static func gitRemoteURL(cwd: String) -> (value: String?, degraded: Bool) {
        let origin = gitLookup(["remote", "get-url", "origin"], cwd: cwd)
        if let originURL = origin.value {
            return (originURL, false)
        }
        guard !origin.degraded else { return (nil, true) }

        let availableRemotes = gitLookup(["remote"], cwd: cwd)
        guard let remotes = availableRemotes.value else {
            return (nil, availableRemotes.degraded)
        }
        guard let firstRemote = remotes
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first else {
            return (nil, false)
        }
        let fallback = gitLookup(["remote", "get-url", firstRemote], cwd: cwd)
        return (fallback.value, fallback.degraded)
    }

    private static func gitMainDirectory(cwd: String, fallbackTopLevel: String) -> (value: String, degraded: Bool) {
        let common = gitLookup(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: cwd)
        guard let commonGitDirectory = common.value else {
            // On failure we fall back to the worktree's own top level, which makes
            // `isGitWorktree` read `false`. Flag `degraded` so that false-negative
            // isn't cached over a good reading.
            return (standardizedPath(fallbackTopLevel), common.degraded)
        }

        let url = URL(fileURLWithPath: standardizedPath(commonGitDirectory)).standardizedFileURL
        if url.lastPathComponent == ".git" {
            return (url.deletingLastPathComponent().path, false)
        }
        return (url.path, false)
    }

    private static func isDefaultBranch(_ branch: String, cwd: String) -> (value: Bool, degraded: Bool) {
        if branch == "main" || branch == "master" {
            return (true, false)
        }
        let remoteHead = gitLookup(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd
        )
        guard let value = remoteHead.value else {
            return (false, remoteHead.degraded)
        }
        return (value.split(separator: "/").last.map(String.init) == branch, false)
    }

    private static func normalizedGitAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scpAddress = normalizedSCPGitAddress(trimmed) {
            return scpAddress
        }
        if let urlAddress = normalizedURLGitAddress(trimmed) {
            return urlAddress
        }
        return removeGitSuffix(trimmed)
    }

    private static func normalizedSCPGitAddress(_ value: String) -> String? {
        guard !value.contains("://"),
              let atIndex = value.firstIndex(of: "@"),
              let colonIndex = value[atIndex...].firstIndex(of: ":") else {
            return nil
        }

        let hostStart = value.index(after: atIndex)
        let pathStart = value.index(after: colonIndex)
        let host = value[hostStart..<colonIndex].lowercased()
        let path = removeGitSuffix(String(value[pathStart...]).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return "\(host)/\(path)"
    }

    private static func normalizedURLGitAddress(_ value: String) -> String? {
        guard var components = URLComponents(string: value), let host = components.host else {
            return nil
        }
        components.user = nil
        components.password = nil
        let path = removeGitSuffix(components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !path.isEmpty else { return host.lowercased() }
        return "\(host.lowercased())/\(path)"
    }

    private static func gitAddressTitle(_ value: String) -> String {
        let components = value
            .split(separator: "/")
            .map(String.init)
        if components.count >= 3 {
            return components.suffix(2).joined(separator: "/")
        }
        return components.last ?? value
    }

    private static func removeGitSuffix(_ value: String) -> String {
        guard value.lowercased().hasSuffix(".git") else { return value }
        return String(value.dropLast(4))
    }

    /// Runs a git lookup, separating a *trustworthy* negative (git ran and
    /// answered non-zero/empty — e.g. "not a repo", "detached HEAD") from a
    /// *degraded* one (the subprocess timed out or failed to launch, so we don't
    /// actually know the answer). `value` is `nil` in both cases; `degraded`
    /// distinguishes them so callers can avoid caching a false-negative.
    private static func gitLookup(_ arguments: [String], cwd: String) -> (value: String?, degraded: Bool) {
        let output: SubprocessRunner.Output
        do {
            output = try SubprocessRunner.run(
                arguments: ["git", "-C", cwd] + arguments,
                cwd: cwd,
                environment: ProcessInfo.processInfo.environment,
                timeout: gitCommandTimeout
            )
        } catch {
            return (nil, true)
        }
        guard output.terminationStatus == 0 else {
            return (nil, false)
        }
        let text = String(decoding: output.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.isEmpty ? nil : text, false)
    }

    /// Bound for the local git lookups above. Generous enough for a cold cache /
    /// large repo, short enough that a hung git can't stall session enumeration.
    private static let gitCommandTimeout: TimeInterval = 5
}
