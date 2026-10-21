import Foundation

/// Presentation only. Hidden roots include current and future descendants.
public enum SessionBackgroundPolicy {
    public static func hiddenIDs(roots: Set<String>, parents: [String: String]) -> Set<String> {
        var children: [String: [String]] = [:]
        for (child, parent) in parents { children[parent, default: []].append(child) }
        var hidden = roots
        var pending = Array(roots)
        while let id = pending.popLast() {
            for child in children[id] ?? [] where hidden.insert(child).inserted { pending.append(child) }
        }
        return hidden
    }

    public static func revealing(_ id: String, roots: Set<String>, parents: [String: String]) -> Set<String> {
        var result = roots
        var current: String? = id
        var visited: Set<String> = []
        while let next = current, visited.insert(next).inserted {
            result.remove(next); current = parents[next]
        }
        return result
    }
}

public struct SessionBackgroundJournal {
    public let file: URL
    public init(file: URL) { self.file = file }
    public func load() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: file)))
    }
    public func save(_ roots: Set<String>) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(roots.sorted()).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
