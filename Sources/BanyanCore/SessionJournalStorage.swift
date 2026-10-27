import Foundation

/// Keep existing per-session files readable. Other IDs are JSON keys, never
/// path components: creation and reparenting need not impose filesystem limits.
/// The fixed subdirectory cannot collide with a legacy `<id>.json` file.
/// Callers serialize journal mutations, just as for per-session receipt writes.
struct SessionJournalStorage<Record: Codable> {
    let directory: URL

    private func legacyURL(_ id: String) -> URL? {
        guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != "..",
              id.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
              }) else { return nil }
        return directory.appendingPathComponent(id + ".json")
    }

    private var extendedURL: URL {
        directory.appendingPathComponent("extended").appendingPathComponent("records.json")
    }

    private func read<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value? {
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }

    func load(id: String) throws -> Record? {
        if let url = legacyURL(id) { return try read(Record.self, at: url) }
        return try read([String: Record].self, at: extendedURL)?[id]
    }

    func save(_ record: Record, id: String) throws {
        let url: URL
        let data: Data
        if let legacy = legacyURL(id) {
            url = legacy
            data = try JSONEncoder().encode(record)
        } else {
            url = extendedURL
            // A corrupt/unreadable collection must never be replaced with an
            // empty one: it may contain pending receipts for other sessions.
            var records = try read([String: Record].self, at: url) ?? [:]
            records[id] = record
            data = try JSONEncoder().encode(records)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
