import Foundation

public enum SessionDisplayLabel {
    public static func context(cwd: String) -> (project: String, branch: String?) {
        let project = gitOutput(["rev-parse", "--show-toplevel"], cwd: cwd)
            .map(projectName)
            ?? projectName(cwd)
        let branch = gitOutput(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd)
            ?? gitOutput(["rev-parse", "--short", "HEAD"], cwd: cwd)
        return (project, branch)
    }

    public static func make(project: String, branch: String?, title: String, id: String, command: String) -> String {
        var components = [clean(project)]
        if let branch = branch.map(clean), !branch.isEmpty {
            components.append(branch)
        }
        components.append("\"\(truncate(taskTitle(title: title, id: id, command: command), limit: 44))\"")
        return components.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func taskTitle(title: String, id: String, command: String) -> String {
        let cleanedTitle = clean(title)
        if !isGenericTitle(cleanedTitle), !looksLikeHostTitle(cleanedTitle) {
            return cleanedTitle
        }

        let cleanedCommand = clean(command)
        if !cleanedCommand.isEmpty {
            return prettyCommand(cleanedCommand)
        }

        let cleanedID = clean(id)
        if !isGenericTitle(cleanedID), !looksLikeHostTitle(cleanedID) {
            return cleanedID
        }

        return "shell"
    }

    private static func prettyCommand(_ command: String) -> String {
        let shellNames = ["bash", "fish", "sh", "zsh"]
        if shellNames.contains(command) || shellNames.contains(URL(fileURLWithPath: command).lastPathComponent) {
            return "shell"
        }

        for agent in ["codex", "claude"] {
            guard command == agent || command.hasPrefix("\(agent) ") else { continue }
            let suffix = clean(String(command.dropFirst(agent.count)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return suffix.isEmpty ? agent : suffix
        }

        return command
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.isEmpty
            || lowercased == "shell"
            || lowercased.hasPrefix("shell-")
            || lowercased == "session"
            || lowercased.hasPrefix("session-")
    }

    private static func looksLikeHostTitle(_ value: String) -> Bool {
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return !parts[0].contains(" ") && !parts[1].contains(" ")
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
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        let component = url.lastPathComponent
        if component.isEmpty {
            return url.path
        }
        return component
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
