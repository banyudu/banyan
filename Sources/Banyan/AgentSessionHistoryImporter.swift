import BanyanCore
import Foundation

struct ImportedAgentSession: Identifiable, Equatable {
    let id: String
    let provider: CodingAgentProvider
    let sourceID: String
    let title: String
    let cwd: String
    let transcriptURL: URL
    let createdAt: Date
    let updatedAt: Date
}

enum AgentSessionHistoryImporter {
    static func load(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        maxPerProvider: Int = 10,
        fileManager: FileManager = .default
    ) -> [ImportedAgentSession] {
        let codex = loadCodexHistory(
            homeDirectory: homeDirectory,
            maxSessions: maxPerProvider,
            fileManager: fileManager
        )
        let claude = loadClaudeHistory(
            homeDirectory: homeDirectory,
            maxSessions: maxPerProvider,
            fileManager: fileManager
        )
        return (codex + claude).sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private static func loadCodexHistory(
        homeDirectory: URL,
        maxSessions: Int,
        fileManager: FileManager
    ) -> [ImportedAgentSession] {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        let indexURL = codexDirectory.appendingPathComponent("session_index.jsonl")
        let indexContents = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""

        let sessionFiles = recentCodexSessionFiles(
            in: codexDirectory.appendingPathComponent("sessions"),
            maxSessions: maxSessions,
            fileManager: fileManager
        )
        let sessionFilesByID = Dictionary(uniqueKeysWithValues: sessionFiles.map { ($0.id, $0) })

        let indexRows = indexContents
            .split(whereSeparator: \.isNewline)
            .compactMap { parseCodexIndexLine(String($0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxSessions)
        let recentFileRows = sessionFiles
            .map { CodexSessionCandidate(id: $0.id, transcriptURL: $0.url, threadName: nil, updatedAt: $0.modifiedAt) }
        let indexedRows = indexRows.compactMap { row -> CodexSessionCandidate? in
            guard let file = sessionFilesByID[row.id] else { return nil }
            return CodexSessionCandidate(
                id: row.id,
                transcriptURL: file.url,
                threadName: row.threadName,
                updatedAt: row.updatedAt
            )
        }
        let candidates = Dictionary((indexedRows + recentFileRows).map { ($0.id, $0) }) { indexed, _ in indexed }
            .values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxSessions)

        return candidates.compactMap { candidate in
            let metadata = parseCodexMetadata(from: candidate.transcriptURL)
            let cwd = metadata.cwd ?? homeDirectory.path
            return ImportedAgentSession(
                id: importedID(provider: .codex, sourceID: candidate.id),
                provider: .codex,
                sourceID: candidate.id,
                title: metadata.promptTitle ?? sanitizedTitle(candidate.threadName) ?? "Codex \(candidate.id.prefix(8))",
                cwd: cwd,
                transcriptURL: candidate.transcriptURL,
                createdAt: metadata.createdAt ?? candidate.updatedAt,
                updatedAt: candidate.updatedAt
            )
        }
    }

    private static func loadClaudeHistory(
        homeDirectory: URL,
        maxSessions: Int,
        fileManager: FileManager
    ) -> [ImportedAgentSession] {
        let projectsDirectory = homeDirectory.appendingPathComponent(".claude/projects")
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            candidates.append((url, modifiedAt))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxSessions)
            .compactMap { candidate in
                parseClaudeSession(
                    from: candidate.url,
                    fallbackUpdatedAt: candidate.modifiedAt,
                    homeDirectory: homeDirectory
                )
            }
    }

    private static func parseCodexIndexLine(_ line: String) -> CodexIndexRow? {
        guard let object = jsonObject(from: line),
              let id = object["id"] as? String,
              let updatedAt = parseDate(object["updated_at"] as? String) else {
            return nil
        }
        return CodexIndexRow(
            id: id,
            threadName: object["thread_name"] as? String,
            updatedAt: updatedAt
        )
    }

    private static func recentCodexSessionFiles(
        in directory: URL,
        maxSessions: Int,
        fileManager: FileManager
    ) -> [CodexSessionFile] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [CodexSessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let id = stem.split(separator: "-").suffix(5).map(String.init).joined(separator: "-").nilIfEmpty else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast
            result.append(CodexSessionFile(id: id, url: url, modifiedAt: modifiedAt))
        }
        return Array(result.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxSessions))
    }

    private static func parseCodexMetadata(from url: URL) -> (cwd: String?, createdAt: Date?, promptTitle: String?) {
        var cwd: String?
        var createdAt: Date?
        var titleTracker = PromptTitleTracker()

        for line in readLinePrefixAndSuffix(from: url) {
            guard let object = jsonObject(from: line) else {
                continue
            }

            if object["type"] as? String == "session_meta",
               let payload = object["payload"] as? [String: Any] {
                cwd = cwd ?? payload["cwd"] as? String
                createdAt = createdAt
                    ?? parseDate(payload["timestamp"] as? String)
                    ?? parseDate(object["timestamp"] as? String)
            }

            if let prompt = codexUserPrompt(object) {
                titleTracker.observe(prompt)
            }

        }

        return (cwd, createdAt, titleTracker.resolvedTitle)
    }

    private static func parseClaudeSession(
        from url: URL,
        fallbackUpdatedAt: Date,
        homeDirectory: URL
    ) -> ImportedAgentSession? {
        let sourceID = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var createdAt: Date?
        var updatedAt = fallbackUpdatedAt
        var titleTracker = PromptTitleTracker()

        for line in readLinePrefixAndSuffix(from: url) {
            guard let object = jsonObject(from: line) else { continue }
            if cwd == nil {
                cwd = object["cwd"] as? String
            }
            if let timestamp = parseDate(object["timestamp"] as? String) {
                if createdAt == nil {
                    createdAt = timestamp
                }
                updatedAt = max(updatedAt, timestamp)
            }
            if object["type"] as? String == "user",
               let message = object["message"] as? [String: Any],
               let prompt = bodyFromClaudeMessage(message) {
                titleTracker.observe(prompt)
            }
        }

        let resolvedCWD = cwd ?? decodedClaudeProjectPath(from: url, homeDirectory: homeDirectory)
        return ImportedAgentSession(
            id: importedID(provider: .claude, sourceID: sourceID),
            provider: .claude,
            sourceID: sourceID,
            title: titleTracker.resolvedTitle ?? "Claude \(sourceID.prefix(8))",
            cwd: resolvedCWD,
            transcriptURL: url,
            createdAt: createdAt ?? fallbackUpdatedAt,
            updatedAt: updatedAt
        )
    }

    private static func bodyFromClaudeMessage(_ message: [String: Any]) -> String? {
        guard let content = message["content"] else { return nil }
        if let text = content as? String {
            return sanitizedBody(text)
        }
        guard let parts = content as? [[String: Any]] else { return nil }
        for part in parts {
            guard part["type"] as? String == "text",
                  let text = part["text"] as? String,
                  let body = sanitizedBody(text) else {
                continue
            }
            return body
        }
        return nil
    }

    private static func decodedClaudeProjectPath(from url: URL, homeDirectory: URL) -> String {
        let projectName = url.deletingLastPathComponent().lastPathComponent
        guard projectName.hasPrefix("-") else { return homeDirectory.path }
        let decoded = "/" + projectName.dropFirst().replacingOccurrences(of: "-", with: "/")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: decoded, isDirectory: &isDirectory), isDirectory.boolValue {
            return decoded
        }
        return homeDirectory.path
    }

    static func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int = 40) -> String {
        let lines = readLinePrefix(from: url, maxLines: 800, maxBytes: 2_000_000)
        let messages = lines.compactMap { line -> String? in
            guard let object = jsonObject(from: line) else { return nil }
            switch provider {
            case .codex:
                return codexPreviewLine(object)
            case .claude:
                return claudePreviewLine(object)
            default:
                return nil
            }
        }
        let preview = messages.prefix(maxMessages).joined(separator: "\n\n")
        return preview.isEmpty ? "No readable transcript preview is available for this history file." : preview
    }

    static func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? {
        let prefix = "history-\(provider.rawValue)-"
        guard id.hasPrefix(prefix) else { return nil }
        let sourceID = String(id.dropFirst(prefix.count))
        return sourceID.isEmpty ? nil : sourceID
    }

    static func resumeCommand(provider: CodingAgentProvider, sourceID: String, cwd: String, prompt: String? = nil) -> String? {
        let cleanedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String]
        switch provider {
        case .codex:
            arguments = [
                provider.defaultExecutableName,
                "resume",
                "-C",
                cwd,
                sourceID
            ]
        case .claude:
            arguments = [
                provider.defaultExecutableName,
                "--resume",
                sourceID
            ]
        default:
            return nil
        }
        if let cleanedPrompt, !cleanedPrompt.isEmpty {
            arguments.append(cleanedPrompt)
        }
        return arguments.map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    }

    private static func codexPreviewLine(_ object: [String: Any]) -> String? {
        guard let type = object["type"] as? String else { return nil }
        if type == "session_meta", let payload = object["payload"] as? [String: Any] {
            let cwd = payload["cwd"] as? String
            return cwd.map { "Session started in \($0)" }
        }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        if let message = payload["message"] as? [String: Any],
           let role = message["role"] as? String,
           let content = plainText(from: message["content"]) {
            return "\(role.capitalized): \(content)"
        }
        if let text = payload["text"] as? String, let title = sanitizedBody(text) {
            return title
        }
        return nil
    }

    private static func codexUserPrompt(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "user_message",
              let message = payload["message"] as? String else { return nil }
        return sanitizedBody(message)
    }

    private static func claudePreviewLine(_ object: [String: Any]) -> String? {
        guard let type = object["type"] as? String,
              ["user", "assistant"].contains(type),
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String,
              let content = plainText(from: message["content"]) else {
            return nil
        }
        return "\(role.capitalized): \(content)"
    }

    private static func plainText(from value: Any?) -> String? {
        if let text = value as? String {
            return sanitizedBody(text)
        }
        guard let parts = value as? [[String: Any]] else { return nil }
        let texts = parts.compactMap { part -> String? in
            if let text = part["text"] as? String {
                return text
            }
            if let content = part["content"] as? String {
                return content
            }
            return nil
        }
        return sanitizedBody(texts.joined(separator: "\n"))
    }

    private static func sanitizedTitle(_ value: String?) -> String? {
        guard let body = sanitizedBody(value) else { return nil }
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let collapsed = firstLine.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "__cache-warm-ping__" else { return nil }
        return String(trimmed.prefix(80))
    }

    private static func sanitizedBody(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func importedID(provider: CodingAgentProvider, sourceID: String) -> String {
        "history-\(provider.rawValue)-\(sourceID)"
    }

    private struct PromptTitleTracker {
        private var firstTitle: String?
        private var currentSegmentTitle: String?

        var resolvedTitle: String? {
            currentSegmentTitle ?? firstTitle
        }

        mutating func observe(_ prompt: String) {
            if isConversationResetCommand(prompt) {
                currentSegmentTitle = nil
                return
            }
            guard let title = sanitizedTitle(prompt) else { return }
            if firstTitle == nil {
                firstTitle = title
            }
            if currentSegmentTitle == nil {
                currentSegmentTitle = title
            }
        }

        private func isConversationResetCommand(_ prompt: String) -> Bool {
            let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "/clear" || normalized == "/new"
        }
    }

    private static func readLinePrefix(from url: URL, maxLines: Int, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var data = Data()
        var newlineCount = 0
        while data.count < maxBytes, newlineCount < maxLines {
            let chunk = handle.readData(ofLength: min(64 * 1024, maxBytes - data.count))
            if chunk.isEmpty { break }
            newlineCount += chunk.reduce(0) { count, byte in
                byte == 10 ? count + 1 : count
            }
            data.append(chunk)
        }

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .prefix(maxLines)
            .map(String.init)
    }

    private static func readLinePrefixAndSuffix(from url: URL) -> [String] {
        readLinePrefix(from: url, maxLines: 300, maxBytes: 2_000_000)
            + readLineSuffix(from: url, maxLines: 1_500, maxBytes: 4_000_000)
    }

    private static func readLineSuffix(from url: URL, maxLines: Int, maxBytes: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let offset = fileSize > maxBytes ? fileSize - maxBytes : 0
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.suffix(maxLines))
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }
        return internetDateFormatter.date(from: value)
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

private struct CodexIndexRow {
    let id: String
    let threadName: String?
    let updatedAt: Date
}

private struct CodexSessionFile {
    let id: String
    let url: URL
    let modifiedAt: Date
}

private struct CodexSessionCandidate {
    let id: String
    let transcriptURL: URL
    let threadName: String?
    let updatedAt: Date
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
