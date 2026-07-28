import Foundation

/// Locates a coding-agent transcript on disk, runs `TranscriptTrimmer` over it,
/// and writes a trimmed copy as a *new* resumable session — leaving the original
/// transcript untouched. Returns nil on any failure (transcript missing, nothing
/// worth trimming, write error) so callers fall back to a normal full resume.
///
/// Nonisolated so the multi-megabyte read/transform/write runs off the main
/// thread; the caller applies the result on the main actor.
public enum TranscriptResumePreparer {
    public struct Prepared: Equatable {
        public let newSourceID: String
        public let transcriptURL: URL
        public let trimmedCount: Int
        public let bytesSaved: Int

        public init(newSourceID: String, transcriptURL: URL, trimmedCount: Int, bytesSaved: Int) {
            self.newSourceID = newSourceID
            self.transcriptURL = transcriptURL
            self.trimmedCount = trimmedCount
            self.bytesSaved = bytesSaved
        }
    }

    public static func prepare(
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        transcriptURL: URL? = nil,
        newSourceID: String = UUID().uuidString.lowercased(),
        config: TranscriptTrimmer.Config = .default,
        home: URL,
        fileManager: FileManager = .default
    ) -> Prepared? {
        guard [.codex, .claude].contains(provider), !sourceID.isEmpty else { return nil }
        guard let sourceURL = transcriptURL
            ?? locateTranscript(provider: provider, sourceID: sourceID, home: home, fileManager: fileManager)
        else {
            return nil
        }
        guard let contents = try? String(contentsOf: sourceURL, encoding: .utf8) else { return nil }
        guard let outcome = TranscriptTrimmer.trim(
            contents: contents,
            provider: provider,
            oldSessionID: sourceID,
            newSessionID: newSourceID,
            config: config
        ) else {
            return nil
        }
        guard let destinationURL = destinationURL(
            for: sourceURL,
            oldSourceID: sourceID,
            newSourceID: newSourceID
        ) else {
            return nil
        }
        guard (try? Data(outcome.content.utf8).write(to: destinationURL, options: .atomic)) != nil else {
            return nil
        }
        return Prepared(
            newSourceID: newSourceID,
            transcriptURL: destinationURL,
            trimmedCount: outcome.trimmedCount,
            bytesSaved: outcome.bytesSaved
        )
    }

    /// The trimmed copy lives alongside the original so the CLI resolves it the
    /// same way. Claude keys sessions by the bare filename stem; codex embeds the
    /// UUID inside a `rollout-<timestamp>-<uuid>.jsonl` name.
    public static func destinationURL(for sourceURL: URL, oldSourceID: String, newSourceID: String) -> URL? {
        let directory = sourceURL.deletingLastPathComponent()
        switch sourceURL.pathExtension {
        case "jsonl":
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            if stem == oldSourceID {
                return directory.appendingPathComponent("\(newSourceID).jsonl")
            }
            guard stem.contains(oldSourceID) else { return nil }
            let renamed = stem.replacingOccurrences(of: oldSourceID, with: newSourceID)
            return directory.appendingPathComponent("\(renamed).jsonl")
        default:
            return nil
        }
    }

    private static func locateTranscript(
        provider: CodingAgentProvider,
        sourceID: String,
        home: URL,
        fileManager: FileManager
    ) -> URL? {
        switch provider {
        case .claude:
            return firstTranscript(
                under: home.appendingPathComponent(".claude/projects"),
                fileManager: fileManager
            ) { $0.deletingPathExtension().lastPathComponent == sourceID }
        case .codex:
            return firstTranscript(
                under: home.appendingPathComponent(".codex/sessions"),
                fileManager: fileManager
            ) { $0.deletingPathExtension().lastPathComponent.hasSuffix(sourceID) }
        default:
            return nil
        }
    }

    private static func firstTranscript(
        under directory: URL,
        fileManager: FileManager,
        matches: (URL) -> Bool
    ) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" && matches(url) {
            return url
        }
        return nil
    }
}
