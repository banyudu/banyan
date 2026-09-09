import Foundation

/// Reads the thread names Codex generates for its own sessions.
///
/// Codex records a name for every thread in `~/.codex/session_index.jsonl`, an
/// append-only file of `{id, thread_name, updated_at}` rows. Each thread gets
/// two rows: a placeholder written as soon as the first prompt is submitted —
/// the raw prompt cut to a fixed width, mid-word — and, a few seconds later, the
/// title the model generated for the thread. A thread whose title generation did
/// not finish keeps only the placeholder.
///
/// Only the generated name is worth adopting. Banyan already derives a title
/// from the first prompt, and does it better than a blind truncation: it strips
/// filler openers, collapses URLs, and preserves issue IDs. So a thread is
/// reported here only once it has been renamed away from its placeholder, which
/// is what distinguishes the two rows without having to re-read the transcript.
public enum CodexSessionTitleIndex {
    public static func indexURL(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".codex/session_index.jsonl")
    }

    /// Model-generated thread names keyed by Codex thread ID — the same ID that
    /// ends a `rollout-<timestamp>-<id>.jsonl` transcript name.
    public static func generatedTitles(homeDirectory: URL) -> [String: String] {
        let url = indexURL(homeDirectory: homeDirectory)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return generatedTitles(indexContents: contents)
    }

    public static func generatedTitles(indexContents: String) -> [String: String] {
        var namesByThread: [String: [String]] = [:]
        for line in indexContents.split(whereSeparator: \.isNewline) {
            guard let row = parseRow(String(line)) else { continue }
            namesByThread[row.id, default: []].append(row.threadName)
        }

        return namesByThread.reduce(into: [:]) { result, entry in
            // A thread still sitting on its only recorded name has not been
            // titled yet. Two identical names mean the same: nothing renamed it.
            guard let latest = entry.value.last,
                  let first = entry.value.first,
                  latest != first,
                  let title = SessionTitleGenerator.sanitizeTitle(latest),
                  SessionTitleGenerator.isUsefulTitle(title) else {
                return
            }
            result[entry.key] = title
        }
    }

    private static func parseRow(_ line: String) -> (id: String, threadName: String)? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty,
              let threadName = object["thread_name"] as? String else {
            return nil
        }
        return (id, threadName)
    }
}
