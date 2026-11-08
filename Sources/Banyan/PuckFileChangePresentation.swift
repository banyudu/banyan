import Foundation

/// One file in a Codex `fileChange` item. Codex reports an added or deleted
/// file's whole content and an update's unified diff hunks.
struct PuckFileChange: Equatable {
    enum Kind: String { case add, delete, update }

    let path: String
    let kind: Kind
    let movePath: String?
    let diff: String

    /// Changed lines, counting a whole added or deleted file.
    var lineCounts: (added: Int, removed: Int) {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        switch kind {
        case .add: return (lines.filter { !$0.isEmpty }.count, 0)
        case .delete: return (0, lines.filter { !$0.isEmpty }.count)
        case .update:
            return (
                lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count,
                lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            )
        }
    }

    /// A `diff --git` section, so the transcript can highlight it as a diff.
    var unifiedDiff: String {
        let source = Self.side("a", path), target = Self.side("b", movePath ?? path)
        var lines = ["diff --git \(source) \(target)"]
        switch kind {
        case .add:
            lines += ["new file", "--- /dev/null", "+++ \(target)"]
            lines += contentLines.map { "+" + $0 }
        case .delete:
            lines += ["deleted file", "--- \(source)", "+++ /dev/null"]
            lines += contentLines.map { "-" + $0 }
        case .update:
            if !diff.hasPrefix("---") { lines += ["--- \(source)", "+++ \(target)"] }
            lines.append(diff.trimmingCharacters(in: .newlines))
        }
        return lines.joined(separator: "\n")
    }

    /// Codex reports absolute paths; `a/Users/...` reads like a git path.
    private static func side(_ prefix: String, _ path: String) -> String {
        path.hasPrefix("/") ? prefix + path : prefix + "/" + path
    }

    private var contentLines: [String] {
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

enum PuckFileChanges {
    /// Reads the changes from a live `fileChange` item (`{"changes": [...]}`)
    /// or a history row whose text is the bare change list.
    static func parse(_ text: String?) -> [PuckFileChange]? {
        guard let text, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries: [[String: Any]]?
        if let array = value as? [[String: Any]] {
            entries = array
        } else if let object = value as? [String: Any] {
            entries = object["changes"] as? [[String: Any]]
        } else {
            entries = nil
        }
        guard let entries, !entries.isEmpty else { return nil }
        let changes = entries.compactMap { entry -> PuckFileChange? in
            guard let path = entry["path"] as? String else { return nil }
            let kindObject = entry["kind"] as? [String: Any]
            let kindName = (kindObject?["type"] as? String) ?? (entry["kind"] as? String) ?? "update"
            return PuckFileChange(
                path: path,
                kind: PuckFileChange.Kind(rawValue: kindName.lowercased()) ?? .update,
                movePath: (kindObject?["move_path"] ?? kindObject?["movePath"]) as? String,
                diff: entry["diff"] as? String ?? ""
            )
        }
        return changes.isEmpty ? nil : changes
    }

    static func unifiedDiff(_ changes: [PuckFileChange]) -> String {
        changes.map(\.unifiedDiff).joined(separator: "\n")
    }

    /// `Sources/App.swift (+3 −1)`, or `3 files (+10 −2)`.
    static func summary(_ changes: [PuckFileChange], relativeTo root: String? = nil) -> String {
        let added = changes.reduce(0) { $0 + $1.lineCounts.added }
        let removed = changes.reduce(0) { $0 + $1.lineCounts.removed }
        let counts = "(+\(added) −\(removed))"
        guard changes.count == 1, let change = changes.first else { return "\(changes.count) files \(counts)" }
        return "\(displayPath(change.path, relativeTo: root)) \(counts)"
    }

    static func displayPath(_ path: String, relativeTo root: String?) -> String {
        guard let root, !root.isEmpty else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
