import Foundation

public struct SessionProjectContext: Equatable {
    public let project: String
    public let branch: String?
    public let groupID: String
    public let groupTitle: String
    public let isGitWorktree: Bool
    public let isDefaultBranch: Bool
}

public enum SessionDisplayLabel {
    public static func context(cwd: String) -> SessionProjectContext {
        let resolvedCWD = standardizedPath(cwd)
        guard let gitTopLevel = gitOutput(["rev-parse", "--show-toplevel"], cwd: resolvedCWD) else {
            let project = projectName(resolvedCWD)
            return SessionProjectContext(
                project: project,
                branch: nil,
                groupID: "path:\(resolvedCWD)",
                groupTitle: project,
                isGitWorktree: false,
                isDefaultBranch: false
            )
        }

        let project = projectName(gitTopLevel)
        let symbolicBranch = gitOutput(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: resolvedCWD)
        let branch = symbolicBranch ?? gitOutput(["rev-parse", "--short", "HEAD"], cwd: resolvedCWD)
        let mainDirectory = gitMainDirectory(cwd: resolvedCWD, fallbackTopLevel: gitTopLevel)
        let isGitWorktree = standardizedPath(mainDirectory) != standardizedPath(gitTopLevel)
        let isDefaultBranch = symbolicBranch.map { Self.isDefaultBranch($0, cwd: resolvedCWD) } ?? false
        if let remoteURL = gitRemoteURL(cwd: resolvedCWD) {
            let normalizedAddress = normalizedGitAddress(remoteURL)
            return SessionProjectContext(
                project: project,
                branch: branch,
                groupID: "git:\(normalizedAddress)",
                groupTitle: gitAddressTitle(normalizedAddress),
                isGitWorktree: isGitWorktree,
                isDefaultBranch: isDefaultBranch
            )
        }

        return SessionProjectContext(
            project: project,
            branch: branch,
            groupID: "path:\(mainDirectory)",
            groupTitle: projectName(mainDirectory),
            isGitWorktree: isGitWorktree,
            isDefaultBranch: isDefaultBranch
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
        let url = URL(fileURLWithPath: standardizedPath(path)).standardizedFileURL
        let component = url.lastPathComponent
        if component.isEmpty {
            return url.path
        }
        return component
    }

    private static func standardizedPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private static func gitRemoteURL(cwd: String) -> String? {
        if let originURL = gitOutput(["remote", "get-url", "origin"], cwd: cwd) {
            return originURL
        }

        guard let remotes = gitOutput(["remote"], cwd: cwd) else { return nil }
        guard let firstRemote = remotes
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first else {
            return nil
        }
        return gitOutput(["remote", "get-url", firstRemote], cwd: cwd)
    }

    private static func gitMainDirectory(cwd: String, fallbackTopLevel: String) -> String {
        guard let commonGitDirectory = gitOutput(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            cwd: cwd
        ) else {
            return standardizedPath(fallbackTopLevel)
        }

        let url = URL(fileURLWithPath: standardizedPath(commonGitDirectory)).standardizedFileURL
        if url.lastPathComponent == ".git" {
            return url.deletingLastPathComponent().path
        }
        return url.path
    }

    private static func isDefaultBranch(_ branch: String, cwd: String) -> Bool {
        if branch == "main" || branch == "master" {
            return true
        }
        guard let remoteHead = gitOutput(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
            cwd: cwd
        ) else {
            return false
        }
        return remoteHead.split(separator: "/").last.map(String.init) == branch
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

    private static func gitOutput(_ arguments: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", cwd] + arguments

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }
}
