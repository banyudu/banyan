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
    /// Closed sessions are historical records. Their current checkout state is
    /// irrelevant to restoration, and asking git for thousands of old worktrees
    /// can block startup for tens of seconds. Use their saved directory as a
    /// stable display fallback without launching subprocesses.
    public static func historicalContext(cwd: String, homeDirectory: String) -> SessionProjectContext {
        let path = standardizedPath(cwd)
        let project = projectName(path, homeDirectory: homeDirectory)
        return SessionProjectContext(
            project: project,
            branch: nil,
            groupID: "path:\(path)",
            groupTitle: project,
            isGitWorktree: false,
            isDefaultBranch: false,
            gitLookupDegraded: false
        )
    }

    public static func context(
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> SessionProjectContext {
        resolvedContext(cwd: cwd, homeDirectory: homeDirectory, environment: environment).context
    }

    /// `context` plus the path of the `HEAD` file the answer depends on, so a
    /// caller can tell whether re-running these git lookups could produce
    /// anything new. `nil` when the directory is not a repository, or has a git
    /// layout this cannot name without asking git — in which case a caller must
    /// assume the answer can always have changed.
    static func resolvedContext(
        cwd: String,
        homeDirectory: String,
        environment: [String: String]
    ) -> (context: SessionProjectContext, headPath: String?) {
        let resolvedCWD = standardizedPath(cwd)
        let topLevel = gitLookup(
            ["rev-parse", "--show-toplevel"],
            cwd: resolvedCWD,
            environment: environment
        )
        guard let gitTopLevel = topLevel.value else {
            // No top level either means "not a git repo" (a trustworthy answer)
            // or the lookup failed to run — propagate `degraded` so a transient
            // failure isn't cached as "not a worktree".
            let project = projectName(resolvedCWD, homeDirectory: homeDirectory)
            return (SessionProjectContext(
                project: project,
                branch: nil,
                groupID: "path:\(resolvedCWD)",
                groupTitle: project,
                isGitWorktree: false,
                isDefaultBranch: false,
                gitLookupDegraded: topLevel.degraded
            ), nil)
        }

        let headPath = gitHeadPath(topLevel: gitTopLevel)

        var degraded = false
        let project = projectName(gitTopLevel, homeDirectory: homeDirectory)

        let symbolic = gitLookup(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            cwd: resolvedCWD,
            environment: environment
        )
        let symbolicBranch = symbolic.value
        degraded = degraded || symbolic.degraded

        let branch: String?
        if let symbolicBranch {
            branch = symbolicBranch
        } else {
            let shortSHA = gitLookup(
                ["rev-parse", "--short", "HEAD"],
                cwd: resolvedCWD,
                environment: environment
            )
            branch = shortSHA.value
            degraded = degraded || shortSHA.degraded
        }

        let mainDirectory = gitMainDirectory(
            cwd: resolvedCWD,
            fallbackTopLevel: gitTopLevel,
            environment: environment
        )
        degraded = degraded || mainDirectory.degraded
        let isGitWorktree = standardizedPath(mainDirectory.value) != standardizedPath(gitTopLevel)

        let defaultBranch = symbolicBranch.map {
            Self.isDefaultBranch($0, cwd: resolvedCWD, environment: environment)
        } ?? (value: false, degraded: false)
        degraded = degraded || defaultBranch.degraded

        var remote = gitRemoteURL(cwd: resolvedCWD, environment: environment)
        if remote.value == nil && isGitWorktree {
            let mainRemote = gitRemoteURL(cwd: mainDirectory.value, environment: environment)
            if mainRemote.value != nil {
                remote = mainRemote
            } else {
                degraded = degraded || mainRemote.degraded
            }
        }
        degraded = degraded || remote.degraded
        if let remoteURL = remote.value {
            let normalizedAddress = normalizedGitAddress(remoteURL)
            return (SessionProjectContext(
                project: project,
                branch: branch,
                groupID: "git:\(normalizedAddress)",
                groupTitle: gitAddressTitle(normalizedAddress),
                isGitWorktree: isGitWorktree,
                isDefaultBranch: defaultBranch.value,
                gitLookupDegraded: degraded
            ), headPath)
        }

        return (SessionProjectContext(
            project: project,
            branch: branch,
            groupID: "path:\(mainDirectory.value)",
            groupTitle: projectName(mainDirectory.value, homeDirectory: homeDirectory),
            isGitWorktree: isGitWorktree,
            isDefaultBranch: defaultBranch.value,
            gitLookupDegraded: degraded
        ), headPath)
    }

    /// The `HEAD` file behind a checkout, without asking git for it.
    ///
    /// `<topLevel>/.git` is a directory in an ordinary checkout and a
    /// `gitdir: …` pointer file in a linked worktree; both layouts put that
    /// checkout's own `HEAD` — the file `git checkout` rewrites — at the end of
    /// that path. Anything else (a `--separate-git-dir` repo, `GIT_DIR` set in
    /// the environment) returns `nil` rather than a guess.
    private static func gitHeadPath(topLevel: String) -> String? {
        let gitEntry = URL(fileURLWithPath: standardizedPath(topLevel)).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitEntry.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return gitEntry.appendingPathComponent("HEAD").path
        }
        guard let contents = try? String(contentsOf: gitEntry, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let gitDirPath = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !gitDirPath.isEmpty else { return nil }
        let gitDir = gitDirPath.hasPrefix("/")
            ? URL(fileURLWithPath: gitDirPath)
            : gitEntry.deletingLastPathComponent().appendingPathComponent(gitDirPath)
        return gitDir.standardizedFileURL.appendingPathComponent("HEAD").path
    }

    /// The directory a repository-level action should open: the main checkout of
    /// the repository containing `cwd`. A worktree (`<repo>/.worktrees/x`) and a
    /// subdirectory (`<repo>/a/b`) both resolve to `<repo>`; a path outside any
    /// git repository resolves to itself.
    ///
    /// Only for controls that act on the project as a whole — the sidebar
    /// project header's "+". Session-level controls (`Cmd+N`, the toolbar "+")
    /// deliberately keep inheriting the selected session's own directory.
    public static func workspaceRoot(
        cwd: String,
        environment: [String: String]
    ) -> String {
        let resolvedCWD = standardizedPath(cwd)
        guard let topLevel = gitLookup(
            ["rev-parse", "--show-toplevel"],
            cwd: resolvedCWD,
            environment: environment
        ).value else {
            // Not a repository, or the lookup failed to run: this directory is
            // the only answer we can trust.
            return resolvedCWD
        }
        let mainDirectory = gitMainDirectory(
            cwd: resolvedCWD,
            fallbackTopLevel: topLevel,
            environment: environment
        ).value
        // `--git-common-dir` names the git directory, whose parent is a checkout
        // only for the ordinary `<repo>/.git` layout. A submodule
        // (`<repo>/.git/modules/<name>`) or a `--separate-git-dir` repository
        // would otherwise open a session inside git internals, so require a
        // working tree and fall back to this checkout's own top level.
        guard isWorkingTreeRoot(mainDirectory) else {
            return standardizedPath(topLevel)
        }
        return mainDirectory
    }

    private static func isWorkingTreeRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path
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

    private static func projectName(_ path: String, homeDirectory: String) -> String {
        let canonicalPath = standardizedPath(path)
        let homePath = PathDisplayName.canonicalPath(homeDirectory)
        if canonicalPath == homePath || canonicalPath.hasPrefix(homePath + "/") {
            return PathDisplayName.make(path: canonicalPath, homeDirectory: homeDirectory)
        }

        let url = URL(fileURLWithPath: canonicalPath).standardizedFileURL
        let component = url.lastPathComponent
        return component.isEmpty ? url.path : component
    }

    private static func standardizedPath(_ path: String) -> String {
        PathDisplayName.canonicalPath(path)
    }

    private static func gitRemoteURL(
        cwd: String,
        environment: [String: String]
    ) -> (value: String?, degraded: Bool) {
        let origin = gitLookup(
            ["remote", "get-url", "origin"],
            cwd: cwd,
            environment: environment
        )
        if let originURL = origin.value {
            return (originURL, false)
        }
        guard !origin.degraded else { return (nil, true) }

        let availableRemotes = gitLookup(
            ["remote"],
            cwd: cwd,
            environment: environment,
            emptyOutputIsDegraded: false
        )
        guard let remotes = availableRemotes.value else {
            return (nil, availableRemotes.degraded)
        }
        guard let firstRemote = remotes
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first else {
            return (nil, false)
        }
        let fallback = gitLookup(
            ["remote", "get-url", firstRemote],
            cwd: cwd,
            environment: environment
        )
        return (fallback.value, fallback.degraded)
    }

    private static func gitMainDirectory(
        cwd: String,
        fallbackTopLevel: String,
        environment: [String: String]
    ) -> (value: String, degraded: Bool) {
        let common = gitLookup(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: cwd,
            environment: environment
        )
        if let commonGitDirectory = common.value {
            let url = URL(fileURLWithPath: standardizedPath(commonGitDirectory)).standardizedFileURL
            if url.lastPathComponent == ".git" {
                return (url.deletingLastPathComponent().path, false)
            }
            return (url.path, false)
        }

        if let mainDir = mainDirectoryFromWorktreeGitFile(topLevel: fallbackTopLevel) {
            return (mainDir, false)
        }

        return (standardizedPath(fallbackTopLevel), common.degraded)
    }

    private static func mainDirectoryFromWorktreeGitFile(topLevel: String) -> String? {
        let gitFile = URL(fileURLWithPath: topLevel).appendingPathComponent(".git")
        guard let contents = try? String(contentsOf: gitFile, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let gitdirPath = trimmed.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespaces)
        let resolved: String
        if gitdirPath.hasPrefix("/") {
            resolved = gitdirPath
        } else {
            resolved = URL(fileURLWithPath: topLevel)
                .appendingPathComponent(gitdirPath).standardizedFileURL.path
        }
        let url = URL(fileURLWithPath: standardizedPath(resolved)).standardizedFileURL
        guard url.path.contains("/worktrees/") else { return nil }
        var current = url
        while current.lastPathComponent != "worktrees" && current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        guard current.lastPathComponent == "worktrees" else { return nil }
        let gitDir = current.deletingLastPathComponent()
        if gitDir.lastPathComponent == ".git" {
            return gitDir.deletingLastPathComponent().path
        }
        return gitDir.path
    }

    private static func isDefaultBranch(
        _ branch: String,
        cwd: String,
        environment: [String: String]
    ) -> (value: Bool, degraded: Bool) {
        if branch == "main" || branch == "master" {
            return (true, false)
        }
        let remoteHead = gitLookup(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd,
            environment: environment
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
    /// - Parameter emptyOutputIsDegraded: Most lookups here (`--show-toplevel`,
    ///   `remote get-url`, …) never legitimately succeed with empty stdout, so a
    ///   0-exit with no output means the pipe drain lost the data (it happens
    ///   under startup load) rather than a real answer. Callers whose command
    ///   can genuinely print nothing (`git remote` in a remoteless repo) pass
    ///   `false` to keep treating that as a trustworthy negative.
    private static func gitLookup(
        _ arguments: [String],
        cwd: String,
        environment: [String: String],
        emptyOutputIsDegraded: Bool = true
    ) -> (value: String?, degraded: Bool) {
        let output: SubprocessRunner.Output
        do {
            output = try SubprocessRunner.run(
                arguments: ["git", "-C", cwd] + arguments,
                cwd: cwd,
                environment: environment,
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
        if text.isEmpty {
            return (nil, emptyOutputIsDegraded)
        }
        return (text, false)
    }

    /// Bound for the local git lookups above. Generous enough for a cold cache /
    /// large repo, short enough that a hung git can't stall session enumeration.
    private static let gitCommandTimeout: TimeInterval = 5
}
