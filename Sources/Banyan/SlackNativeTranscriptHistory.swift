import BanyanCore
import Foundation

/// Resolves only an exact native thread ID under its recorded Codex home. The
/// bounded directory walk reads names, not transcript bodies; the shared reader
/// loads a bounded window only after a session is opened.
actor SlackNativeTranscriptHistory {
    private struct Key: Hashable { let home: String; let threadID: String }
    private var paths: [Key: URL] = [:]
    private var pathOrder: [Key] = []
    private let history = ConversationHistoryReader()
    private let maximumEntries = 100_000

    func page(sessionID: String, threadID: String, home: String?, earlier: String?, limit: Int) async throws -> ConversationHistoryReader.Page? {
        guard let home, !home.isEmpty, !threadID.isEmpty, threadID.utf8.count <= 128,
              threadID.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else { return nil }
        let root = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL
        let key = Key(home: root.path, threadID: threadID)
        let file: URL
        if earlier == nil {
            guard let found = locate(root: root, threadID: threadID) else {
                paths.removeValue(forKey: key); pathOrder.removeAll { $0 == key }; return nil
            }
            paths[key] = found
            pathOrder.removeAll { $0 == key }; pathOrder.append(key)
            while pathOrder.count > 128 { paths.removeValue(forKey: pathOrder.removeFirst()) }
            file = found
        } else {
            guard let cached = paths[key], FileManager.default.fileExists(atPath: cached.path) else { return nil }
            file = cached
        }
        let identity = ConversationHistoryReader.Identity(provider: .codex, conversationID: threadID,
            transcriptURL: file, ownerSessionID: sessionID)
        let result = try await history.page(identity: identity, earlier: earlier, limit: limit)
        try await history.revalidate(identity: identity, snapshotID: result.snapshotID)
        return result
    }

    private func locate(root: URL, threadID: String) -> URL? {
        var found: URL?
        var count = 0
        for name in ["sessions", "archived_sessions"] {
            guard let entries = FileManager.default.enumerator(at: root.appendingPathComponent(name, isDirectory: true),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                count += 1
                guard count <= maximumEntries else { return nil }
                guard url.lastPathComponent.hasPrefix("rollout-"), url.lastPathComponent.hasSuffix("-\(threadID).jsonl"),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                guard found == nil else { return nil }
                found = url.standardizedFileURL
            }
        }
        return found
    }
}
