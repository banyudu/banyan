import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [BanyanSession] = []
    @Published var selectedSessionID: String?
    @Published var sortMode: SortMode = .manual
    @Published var terminalTheme: TerminalTheme = .system {
        didSet {
            sessions.forEach { $0.apply(theme: terminalTheme) }
        }
    }

    private var controlServer: ControlServer?

    var visibleSessions: [BanyanSession] {
        let active = sessions.filter { $0.status != .closed }
        switch sortMode {
        case .manual:
            return active
        case .status:
            return active.sorted {
                if $0.status.priority == $1.status.priority {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.status.priority < $1.status.priority
            }
        case .updated:
            return active.sorted { $0.updatedAt > $1.updatedAt }
        case .title:
            return active.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var selectedSession: BanyanSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    func startControlServer() {
        guard controlServer == nil else { return }
        let server = ControlServer(store: self)
        server.start()
        controlServer = server
    }

    @discardableResult
    func spawn(
        id proposedID: String? = nil,
        title proposedTitle: String? = nil,
        cwd proposedCWD: String? = nil,
        command proposedCommand: String? = nil,
        tone: SessionTone = .blue
    ) -> BanyanSession {
        let baseID = sanitizeID(proposedID ?? proposedTitle ?? "session")
        let id = uniqueID(baseID)
        let cwd = resolvedWorkingDirectory(proposedCWD)
        let command = proposedCommand ?? ""
        let title = proposedTitle?.isEmpty == false ? proposedTitle! : id
        let session = BanyanSession(
            id: id,
            title: title,
            cwd: cwd,
            command: command,
            tone: tone,
            theme: terminalTheme
        )
        sessions.append(session)
        selectedSessionID = session.id
        session.start()
        return session
    }

    func mark(id: String, status: SessionStatus? = nil, tone: SessionTone? = nil, title: String? = nil) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.mark(status: status, tone: tone, title: title)
    }

    func close(id: String) throws {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        session.terminate(markClosed: true)
        if selectedSessionID == id {
            selectedSessionID = visibleSessions.first?.id
        }
    }

    func remove(id: String) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            throw ControlError.notFound(id)
        }
        sessions[index].terminate(markClosed: true)
        sessions.remove(at: index)
        if selectedSessionID == id {
            selectedSessionID = visibleSessions.first?.id
        }
    }

    func select(id: String) {
        selectedSessionID = id
    }

    private func resolvedWorkingDirectory(_ cwd: String?) -> String {
        let raw = cwd?.isEmpty == false ? cwd! : FileManager.default.currentDirectoryPath
        let expanded = NSString(string: raw).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        return NSHomeDirectory()
    }

    private func sanitizeID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "session" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-_")).isEmpty ? "session" : String(cleaned)
    }

    private func uniqueID(_ baseID: String) -> String {
        if !sessions.contains(where: { $0.id == baseID }) {
            return baseID
        }
        var index = 2
        while sessions.contains(where: { $0.id == "\(baseID)-\(index)" }) {
            index += 1
        }
        return "\(baseID)-\(index)"
    }
}

enum ControlError: LocalizedError {
    case notFound(String)
    case badRequest(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No session found for id '\(id)'"
        case .badRequest(let message): return message
        }
    }
}
