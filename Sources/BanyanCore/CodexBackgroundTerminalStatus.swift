import Foundation

/// Codex's live footer reports terminal sessions, not descendant process count:
/// one dev server may own several workers. Require the footer beside the current
/// composer so an old `/ps` response or quoted output is not treated as live.
enum CodexBackgroundTerminalStatus {
    private static let footer = try! NSRegularExpression(
        pattern: #"(?m)(?:^|[·•]\s+)([1-9][0-9]*) background terminals? running\s*·\s*/ps to view(?:\s*·\s*/stop to close)?\s*\z"#
    )

    static func count(in text: String) -> Int {
        let lines = text.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard let composer = lines.lastIndex(where: { $0.hasPrefix("›") }) else { return 0 }
        let aboveComposer = lines[..<composer]
        let end = aboveComposer.lastIndex {
            $0.lowercased() == "• queued follow-up inputs"
                || $0.lowercased().hasPrefix("• messages to be submitted after next tool call (")
        } ?? composer
        // The footer can wrap on narrow panes. It sits directly above the
        // composer (or the queued-input block), after any conversation output.
        let tail = lines[..<end].suffix(3).joined(separator: "\n")
        guard let match = footer.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
              let range = Range(match.range(at: 1), in: tail) else { return 0 }
        return Int(tail[range]) ?? 0
    }
}
