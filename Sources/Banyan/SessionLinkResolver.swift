import AppKit
import BanyanCore
import Foundation

struct SessionLinkContext {
    let cwd: String
    let environment: [String: String]
    let homeDirectory: String
    var repositoryGroupID: String? = nil
    var cache: GitHubReferenceCache? = nil
}

enum SessionLinkTarget {
    case reference(String)
    case url(URL)
}

/// One destination policy for terminal references and native transcript links.
enum SessionLinkResolver {
    private static let referenceScheme = "banyan-session-reference"

    /// Native text needs a URL attribute even when resolution requires a GitHub
    /// lookup or the session directory. Resolve those references only on click.
    static func referenceURL(_ text: String, environment: [String: String]) -> URL? {
        if let id = linearIssueID(in: text) {
            return url(LinearIssueReference.issueURL(for: id, environment: environment))
        }
        if let direct = URL(string: text), direct.scheme != nil {
            return url(text)
        }
        var components = URLComponents()
        components.scheme = referenceScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        return components.url
    }

    static func resolve(_ target: SessionLinkTarget, context: SessionLinkContext) async -> URL? {
        let destination: URL?
        switch target {
        case .url(let supplied):
            if supplied.scheme == referenceScheme {
                guard supplied.host == "open",
                      let items = URLComponents(url: supplied, resolvingAgainstBaseURL: false)?.queryItems,
                      items.count == 1, items[0].name == "text", let text = items[0].value else { return nil }
                return await resolve(.reference(text), context: context)
            }
            // A Markdown destination named TASK-123 is a relative file, not an
            // implicit issue reference. Decode percent escapes only for paths.
            let value = supplied.scheme == nil ? supplied.path : supplied.absoluteString
            destination = url(value, relativeTo: context.cwd, homeDirectory: context.homeDirectory)
        case .reference(let text):
            if let id = linearIssueID(in: text) {
                destination = url(LinearIssueReference.issueURL(for: id, environment: context.environment))
            } else if let number = referenceNumber(in: text) {
                return await GitHubReferenceResolver.resolve(
                    number: number, cwd: context.cwd, environment: context.environment,
                    homeDirectory: context.homeDirectory, repositoryGroupID: context.repositoryGroupID,
                    cache: context.cache
                )
            } else {
                destination = url(text, relativeTo: context.cwd, homeDirectory: context.homeDirectory)
            }
        }
        guard let destination else { return nil }
        if destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) { return nil }
        return destination
    }

    @MainActor
    static func open(
        _ target: SessionLinkTarget,
        context: SessionLinkContext,
        action: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        Task.detached(priority: .utility) {
            let destination = await resolve(target, context: context)
            await MainActor.run {
                if let destination { action(destination) } else { NSSound.beep() }
            }
        }
    }

    static func linearIssueID(in link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = LinearIssueReference.issueID(in: trimmed),
              trimmed.caseInsensitiveCompare(id) == .orderedSame else { return nil }
        return id
    }

    static func referenceNumber(in link: String) -> Int? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.hasPrefix("#") else { return nil }
        let digits = trimmed.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    static func url(
        _ link: String,
        relativeTo baseDirectory: String? = nil,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        if value.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(String(value.dropFirst(2))).standardizedFileURL
        }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
            if ["http", "https"].contains(scheme), url.host != nil { return url }
            return url.isFileURL ? url : nil
        }
        guard let baseDirectory, !baseDirectory.isEmpty else { return nil }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true))
            .standardizedFileURL
    }
}

extension BanyanSession {
    var linkContext: SessionLinkContext {
        SessionLinkContext(cwd: cwd, environment: environment, homeDirectory: homeDirectory,
                           repositoryGroupID: projectGroupID, cache: githubReferenceCache)
    }
}
