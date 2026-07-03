import Foundation

struct SessionSnapshot: Codable {
    let id: String
    let tmuxSessionName: String?
    let title: String
    let reportedTitle: String?
    let cwd: String
    let command: String
    let status: SessionStatus
    let tone: SessionTone
    let createdAt: Date
    let updatedAt: Date
}

struct SessionPersistence {
    private let fileURL: URL

    init(fileURL: URL = SessionPersistence.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() -> [SessionSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionSnapshot].self, from: data)) ?? []
    }

    func save(_ snapshots: [SessionSnapshot]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshots).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Banyan failed to persist sessions: \(error.localizedDescription)")
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Banyan/sessions.json")
    }
}
