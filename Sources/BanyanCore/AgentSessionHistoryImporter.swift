import Foundation

public enum AgentSessionHistoryImporter {
    public static func load(
        homeDirectory: URL,
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

    /// Conversations recorded for `cwd`, found without reading transcript bodies.
    ///
    /// `load` reads up to 2 MB of head and 4 MB of tail from every transcript to
    /// derive titles. Resume matching needs none of that — only the provider,
    /// working directory and timestamps — so a reopen that fell back to a
    /// full-corpus `load` spent minutes parsing prompt text it then discarded.
    /// Codex records `cwd` in the `session_meta` object on line 1, and Claude
    /// both encodes it in the project directory name and repeats it on the first
    /// few lines, so each provider can be narrowed before any body is touched.
    ///
    /// `maxFilesScanned` bounds the worst case as local history keeps growing;
    /// files are visited newest-first, so the cap only ever drops the oldest
    /// conversations.
    public static func resumeCandidates(
        homeDirectory: URL,
        cwd: String,
        provider: CodingAgentProvider?,
        maxFilesScanned: Int = 20_000,
        fileManager: FileManager = .default
    ) -> [AgentResumeCandidate] {
        let normalizedCWD = PathDisplayName.canonicalPath(cwd)
        var candidates: [AgentResumeCandidate] = []
        if provider == nil || provider == .codex {
            candidates += codexResumeCandidates(
                homeDirectory: homeDirectory,
                normalizedCWD: normalizedCWD,
                maxFilesScanned: maxFilesScanned,
                fileManager: fileManager
            )
        }
        if provider == nil || provider == .claude {
            candidates += claudeResumeCandidates(
                homeDirectory: homeDirectory,
                cwd: cwd,
                normalizedCWD: normalizedCWD,
                maxFilesScanned: maxFilesScanned,
                fileManager: fileManager
            )
        }
        return candidates
    }

    private static func codexResumeCandidates(
        homeDirectory: URL,
        normalizedCWD: String,
        maxFilesScanned: Int,
        fileManager: FileManager
    ) -> [AgentResumeCandidate] {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        let files = recentCodexSessionFiles(
            in: codexDirectory.appendingPathComponent("sessions"),
            maxSessions: maxFilesScanned,
            fileManager: fileManager
        )
        guard !files.isEmpty else { return [] }
        // The index is one small file and carries the thread's last activity,
        // which tracks the conversation more closely than the rollout's mtime.
        let indexUpdatedAt = codexIndexUpdatedAt(homeDirectory: homeDirectory)
        return files.compactMap { file in
            guard let meta = codexSessionMeta(from: file.url),
                  PathDisplayName.canonicalPath(meta.cwd) == normalizedCWD else {
                return nil
            }
            return AgentResumeCandidate(
                provider: .codex,
                sourceID: file.id,
                cwd: meta.cwd,
                createdAt: meta.createdAt ?? file.modifiedAt,
                updatedAt: indexUpdatedAt[file.id] ?? file.modifiedAt
            )
        }
    }

    private static func claudeResumeCandidates(
        homeDirectory: URL,
        cwd: String,
        normalizedCWD: String,
        maxFilesScanned: Int,
        fileManager: FileManager
    ) -> [AgentResumeCandidate] {
        let projectsDirectory = homeDirectory.appendingPathComponent(".claude/projects")
        let files = claudeTranscriptFiles(
            in: projectsDirectory,
            matching: cwd,
            maxFilesScanned: maxFilesScanned,
            fileManager: fileManager
        )
        return files.compactMap { file in
            guard let meta = claudeSessionMeta(from: file.url) else { return nil }
            let resolvedCWD = meta.cwd
                ?? decodedClaudeProjectPath(from: file.url, homeDirectory: homeDirectory)
            guard PathDisplayName.canonicalPath(resolvedCWD) == normalizedCWD else { return nil }
            return AgentResumeCandidate(
                provider: .claude,
                sourceID: file.url.deletingPathExtension().lastPathComponent,
                cwd: resolvedCWD,
                createdAt: meta.createdAt ?? file.modifiedAt,
                updatedAt: file.modifiedAt
            )
        }
    }

    /// Claude names each project directory after the working directory with every
    /// non-alphanumeric character replaced by `-`, so the directory list narrows
    /// the search without opening a single transcript. The encoding is lossy and
    /// undocumented, so a miss falls back to walking every project — still only
    /// head reads, and still bounded.
    private static func claudeTranscriptFiles(
        in projectsDirectory: URL,
        matching cwd: String,
        maxFilesScanned: Int,
        fileManager: FileManager
    ) -> [(url: URL, modifiedAt: Date)] {
        let directories = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        // Claude encodes whatever path it was launched in, which need not be the
        // symlink-resolved one — `/tmp/x` and `/private/tmp/x` name the same
        // directory but encode differently — so try both spellings.
        let encodedNames: Set<String> = [
            encodedClaudeProjectName(for: cwd),
            encodedClaudeProjectName(for: PathDisplayName.canonicalPath(cwd))
        ]
        let scoped = directories.filter { encodedNames.contains($0.lastPathComponent) }
        let searchRoots = scoped.isEmpty ? [projectsDirectory] : scoped

        var files: [(url: URL, modifiedAt: Date)] = []
        for root in searchRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                // Subagent journals are implementation artifacts, not resumable
                // top-level conversations. `load` skips them for the same reason.
                let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
                guard !relativePath.split(separator: "/").contains("subagents"),
                      url.lastPathComponent != "journal.jsonl" else {
                    continue
                }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                files.append((url, modifiedAt))
            }
        }
        return Array(files.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxFilesScanned))
    }

    private static func encodedClaudeProjectName(for cwd: String) -> String {
        String(cwd.map { character in
            character.isLetter || character.isNumber ? character : "-"
        })
    }

    /// Codex writes `session_meta` as the very first line of a rollout, so the
    /// working directory and start time cost one read of the file's head.
    private static func codexSessionMeta(from url: URL) -> (cwd: String, createdAt: Date?)? {
        guard let line = readFirstLine(from: url, maxBytes: 1_000_000),
              let object = jsonObject(from: line),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        let createdAt = parseDate(payload["timestamp"] as? String)
            ?? parseDate(object["timestamp"] as? String)
        return (cwd, createdAt)
    }

    /// Claude opens a transcript with a few settings rows before the first row
    /// that carries `cwd`, so this reads a short head rather than one line.
    private static func claudeSessionMeta(from url: URL) -> (cwd: String?, createdAt: Date?)? {
        var cwd: String?
        var createdAt: Date?
        for line in readLinePrefix(from: url, maxLines: 40, maxBytes: 512_000) {
            guard let object = jsonObject(from: line) else { continue }
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty {
                cwd = value
            }
            if createdAt == nil {
                createdAt = parseDate(object["timestamp"] as? String)
            }
            if cwd != nil, createdAt != nil { break }
        }
        guard cwd != nil || createdAt != nil else { return nil }
        return (cwd, createdAt)
    }

    private static func codexIndexUpdatedAt(homeDirectory: URL) -> [String: Date] {
        let url = CodexSessionTitleIndex.indexURL(homeDirectory: homeDirectory)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: Date] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let row = parseCodexIndexLine(String(line)) else { continue }
            if let existing = result[row.id], existing >= row.updatedAt { continue }
            result[row.id] = row.updatedAt
        }
        return result
    }

    private static func loadCodexHistory(
        homeDirectory: URL,
        maxSessions: Int,
        fileManager: FileManager
    ) -> [ImportedAgentSession] {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex")
        let indexURL = codexDirectory.appendingPathComponent("session_index.jsonl")
        let indexContents = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        let generatedTitles = CodexSessionTitleIndex.generatedTitles(indexContents: indexContents)

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
            // Codex names its own threads a few seconds after the first prompt.
            // That name beats anything derived from the prompt text, so prefer
            // it once it exists and fall back to the prompt until then.
            let generatedTitle = metadata.segmentWasCleared ? nil : generatedTitles[candidate.id]
            return ImportedAgentSession(
                id: importedID(provider: .codex, sourceID: candidate.id),
                provider: .codex,
                sourceID: candidate.id,
                title: generatedTitle
                    ?? metadata.promptTitle
                    ?? sanitizedTitle(candidate.threadName)
                    ?? "Codex \(candidate.id.prefix(8))",
                segmentPromptTitle: metadata.segmentTitle,
                segmentWasCleared: metadata.segmentWasCleared,
                agentGeneratedTitle: generatedTitle,
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
            // Claude stores subagent workflow journals and transcripts beneath
            // the project directory too. They are implementation artifacts,
            // not resumable top-level conversations. In particular, every
            // workflow uses the basename `journal.jsonl`; importing them would
            // create duplicate history IDs across projects and can make
            // downstream unique-key dictionaries trap.
            let relativePath = url.path.replacingOccurrences(of: projectsDirectory.path + "/", with: "")
            guard !relativePath.split(separator: "/").contains("subagents"),
                  url.lastPathComponent != "journal.jsonl" else {
                continue
            }
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

    private static func parseCodexMetadata(from url: URL) -> (cwd: String?, createdAt: Date?, promptTitle: String?, segmentTitle: String?, segmentWasCleared: Bool) {
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

        return (cwd, createdAt, titleTracker.resolvedTitle, titleTracker.segmentTitle, titleTracker.segmentWasCleared)
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
               !isSkippableClaudeUserObject(object),
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
            segmentPromptTitle: titleTracker.segmentTitle,
            segmentWasCleared: titleTracker.segmentWasCleared,
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

    public static func transcriptPreview(from url: URL, provider: CodingAgentProvider, maxMessages: Int = 40) -> String {
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
        if type == "user", isSkippableClaudeUserObject(object) {
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
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        guard !isClaudeLocalCommandText(trimmed) else { return nil }
        return trimmed
    }

    private static func isSkippableClaudeUserObject(_ object: [String: Any]) -> Bool {
        if object["isMeta"] as? Bool == true {
            return true
        }
        guard let message = object["message"] as? [String: Any] else {
            return false
        }
        return isClaudeLocalCommandContent(message["content"])
    }

    private static func isClaudeLocalCommandContent(_ value: Any?) -> Bool {
        if let text = value as? String {
            return isClaudeLocalCommandText(text)
        }
        guard let parts = value as? [[String: Any]] else {
            return false
        }
        return parts.contains { part in
            if let text = part["text"] as? String, isClaudeLocalCommandText(text) {
                return true
            }
            if let content = part["content"] as? String, isClaudeLocalCommandText(content) {
                return true
            }
            return false
        }
    }

    private static func isClaudeLocalCommandText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let localCommandTags = [
            "command-args",
            "command-message",
            "command-name",
            "local-command-caveat",
            "local-command-stderr",
            "local-command-stdout"
        ]
        return localCommandTags.contains { tag in
            trimmed.range(
                of: #"^<\#(tag)(?:\s[^>]*)?>"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func importedID(provider: CodingAgentProvider, sourceID: String) -> String {
        "history-\(provider.rawValue)-\(sourceID)"
    }

    private struct PromptTitleTracker {
        private var firstTitle: String?
        private var currentSegmentTitle: String?
        private var sawResetWithoutPrompt = false

        var resolvedTitle: String? {
            currentSegmentTitle ?? firstTitle
        }

        /// Title of the conversation's current segment — the first prompt after
        /// the most recent /clear or /new. Nil right after a reset until a new
        /// prompt arrives. Unlike `resolvedTitle`, it never falls back to the
        /// pre-reset first prompt, so callers can tell a freshly cleared
        /// conversation apart from one that still carries its original title.
        var segmentTitle: String? {
            currentSegmentTitle
        }

        /// True when the transcript's most recent segment boundary was a
        /// /clear or /new that has no prompt after it yet. Distinguishes a
        /// freshly cleared conversation (title should be dropped) from a
        /// brand-new session that simply hasn't been titled — where
        /// `segmentTitle` is also nil but no reset was ever observed.
        var segmentWasCleared: Bool {
            sawResetWithoutPrompt
        }

        mutating func observe(_ prompt: String) {
            if isConversationResetCommand(prompt) {
                currentSegmentTitle = nil
                sawResetWithoutPrompt = true
                return
            }
            guard let title = sanitizedTitle(prompt) else { return }
            if firstTitle == nil {
                firstTitle = title
            }
            if currentSegmentTitle == nil {
                currentSegmentTitle = title
            }
            sawResetWithoutPrompt = false
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

    private static func readFirstLine(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: min(64 * 1024, maxBytes - data.count))
            if chunk.isEmpty { break }
            data.append(chunk)
            if let newline = data.firstIndex(of: 0x0A) {
                return String(data: data[..<newline], encoding: .utf8)
            }
        }
        return data.isEmpty ? nil : String(data: data, encoding: .utf8)
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
