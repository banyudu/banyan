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
}

enum SessionContextResolver {
    static func resolve(input: SessionContextLookupInput) -> SessionContextInfo {
        let projectContext = SessionDisplayLabel.context(cwd: input.cwd)
        let detectedIssueID = LinearIssueReference.issueID(in: input.title)
            ?? LinearIssueReference.issueID(in: input.titleURL)
            ?? LinearIssueReference.issueID(in: input.displayTitle)
            ?? LinearIssueReference.detect(branch: projectContext.branch, cwd: input.cwd)?.id
        let linearURL = detectedIssueID.map(LinearIssueReference.issueURL(for:))
        let linearTitle = detectedIssueID.flatMap { issueID in
            commandOutput(["linear", "issue", "title", issueID], cwd: input.cwd)
        }
        let pullRequest = pullRequest(cwd: input.cwd)

        return SessionContextInfo(
            sessionID: input.sessionID,
            signature: input.signature,
            linearIssueID: detectedIssueID,
            linearIssueTitle: linearTitle,
            linearIssueURL: linearURL,
            pullRequestNumber: pullRequest?.number,
            pullRequestTitle: pullRequest?.title,
            pullRequestURL: pullRequest?.url
        )
    }

    private struct PullRequestPayload: Decodable {
        let url: String
        let title: String?
        let number: Int?
    }

    private static func pullRequest(cwd: String) -> PullRequestPayload? {
        guard let output = commandOutput(
            ["gh", "pr", "view", "--json", "url,title,number"],
            cwd: cwd
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(PullRequestPayload.self, from: Data(output.utf8))
    }

    private static func commandOutput(_ arguments: [String], cwd: String, timeout: TimeInterval = 4) -> String? {
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

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
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
        var environment = ProcessInfo.processInfo.environment
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
        let existingPath = environment["PATH"] ?? ""
        environment["PATH"] = (additions + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { paths, path in
                if !paths.contains(path) {
                    paths.append(path)
                }
            }
            .joined(separator: ":")
        return environment
    }
}
