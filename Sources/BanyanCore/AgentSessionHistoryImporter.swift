import Foundation

public enum AgentSessionHistoryImporter {
    public static func load(
        homeDirectory: URL,
        maxPerProvider: Int = 10,
        fileManager: FileManager = .default,
        cache: AgentSessionHistoryImportCache? = nil
    ) -> [ImportedAgentSession] {
        let codex = loadCodexHistory(
            homeDirectory: homeDirectory,
            maxSessions: maxPerProvider,
            fileManager: fileManager,
            cache: cache
        )
        let claude = loadClaudeHistory(
            homeDirectory: homeDirectory,
            maxSessions: maxPerProvider,
            fileManager: fileManager,
            cache: cache
        )
        let opencode = OpenCodeHistory.load(
            homeDirectory: homeDirectory,
            maxSessions: maxPerProvider,
            fileManager: fileManager
        )
        return (codex + claude + opencode).sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// Finds the exact transcript for a live provider session without importing
    /// the rest of the provider's history. Codex rollout files live under the
    /// local creation day; Claude names the file after the session ID.
    public static func transcriptURL(
        homeDirectory: URL,
        provider: CodingAgentProvider,
        sourceID: String,
        cwd: String,
        createdAt: Date,
        fileManager: FileManager = .default,
        calendar: Calendar = .current
    ) -> URL? {
        guard !sourceID.isEmpty else { return nil }
        switch provider {
        case .codex:
            return codexTranscriptURL(
                homeDirectory: homeDirectory,
                sourceID: sourceID,
                createdAt: createdAt,
                fileManager: fileManager,
                calendar: calendar
            )
        case .claude:
            return claudeTranscriptURL(
                homeDirectory: homeDirectory,
                sourceID: sourceID,
                cwd: cwd,
                fileManager: fileManager
            )
        default:
            return nil
        }
    }

    private static func codexTranscriptURL(
        homeDirectory: URL,
        sourceID: String,
        createdAt: Date,
        fileManager: FileManager,
        calendar: Calendar
    ) -> URL? {
        let sessions = homeDirectory
            .appendingPathComponent(".codex")
            .appendingPathComponent("sessions")
        let startOfDay = calendar.startOfDay(for: createdAt)

        // The rollout directory is named in the process's local timezone while
        // the session timestamp is UTC. Checking the adjacent days keeps the
        // lookup exact without assuming a timezone.
        for dayOffset in [-1, 0, 1] {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else {
                continue
            }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = components.year,
                  let month = components.month,
                  let dayOfMonth = components.day else {
                continue
            }
            let directory = sessions
                .appendingPathComponent(String(format: "%04d", year))
                .appendingPathComponent(String(format: "%02d", month))
                .appendingPathComponent(String(format: "%02d", dayOfMonth))
            let files = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            if let match = files.first(where: {
                $0.pathExtension == "jsonl" && codexSessionID(from: $0) == sourceID
            }) {
                return match
            }
        }
        return nil
    }

    private static func claudeTranscriptURL(
        homeDirectory: URL,
        sourceID: String,
        cwd: String,
        fileManager: FileManager
    ) -> URL? {
        let projects = homeDirectory
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        let projectNames = Set([
            encodedClaudeProjectName(for: cwd),
            encodedClaudeProjectName(for: PathDisplayName.canonicalPath(cwd))
        ])
        for projectName in projectNames {
            let candidate = projects
                .appendingPathComponent(projectName)
                .appendingPathComponent(sourceID)
                .appendingPathExtension("jsonl")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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
        if provider == nil || provider?.isOpencodeBacked == true {
            candidates += OpenCodeHistory.resumeCandidates(
                homeDirectory: homeDirectory,
                cwd: cwd,
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
            if let existing = result[row.id], existing.isAtOrAfter(row.updatedAt) { continue }
            result[row.id] = row.updatedAt
        }
        return result
    }

    private static func loadCodexHistory(
        homeDirectory: URL,
        maxSessions: Int,
        fileManager: FileManager,
        cache: AgentSessionHistoryImportCache?
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
            .map {
                CodexSessionCandidate(
                    id: $0.id,
                    transcriptURL: $0.url,
                    threadName: nil,
                    updatedAt: $0.modifiedAt,
                    modifiedAt: $0.modifiedAt,
                    fileSize: $0.fileSize
                )
            }
        let indexedRows = indexRows.compactMap { row -> CodexSessionCandidate? in
            guard let file = sessionFilesByID[row.id] else { return nil }
            return CodexSessionCandidate(
                id: row.id,
                transcriptURL: file.url,
                threadName: row.threadName,
                updatedAt: row.updatedAt,
                modifiedAt: file.modifiedAt,
                fileSize: file.fileSize
            )
        }
        let candidates = Dictionary((indexedRows + recentFileRows).map { ($0.id, $0) }) { indexed, _ in indexed }
            .values
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maxSessions)

        let result = candidates.compactMap { candidate -> ImportedAgentSession? in
            let metadata = cache?.codexMetadata(
                for: candidate.transcriptURL,
                modifiedAt: candidate.modifiedAt,
                fileSize: candidate.fileSize
            ) { parseCodexMetadata(from: candidate.transcriptURL) }
                ?? parseCodexMetadata(from: candidate.transcriptURL)
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
        cache?.retainCodex(Set(candidates.map(\.transcriptURL)))
        return result
    }

    private static func loadClaudeHistory(
        homeDirectory: URL,
        maxSessions: Int,
        fileManager: FileManager,
        cache: AgentSessionHistoryImportCache?
    ) -> [ImportedAgentSession] {
        let projectsDirectory = homeDirectory.appendingPathComponent(".claude/projects")
        guard let enumerator = fileManager.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date, fileSize: Int?)] = []
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
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            candidates.append((
                url,
                values?.contentModificationDate ?? .distantPast,
                values?.contentModificationDate == nil ? nil : values?.fileSize
            ))
        }

        let recent = candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxSessions)
        let result = recent.compactMap { candidate in
            if let cache {
                return cache.claudeSession(
                    for: candidate.url,
                    modifiedAt: candidate.modifiedAt,
                    fileSize: candidate.fileSize
                ) {
                    parseClaudeSession(
                        from: candidate.url,
                        fallbackUpdatedAt: candidate.modifiedAt,
                        homeDirectory: homeDirectory
                    )
                }
            }
            return parseClaudeSession(
                from: candidate.url,
                fallbackUpdatedAt: candidate.modifiedAt,
                homeDirectory: homeDirectory
            )
        }
        cache?.retainClaude(Set(recent.map(\.url)))
        return result
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
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [CodexSessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let id = codexSessionID(from: url) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            result.append(CodexSessionFile(
                id: id,
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                fileSize: values?.contentModificationDate == nil ? nil : values?.fileSize
            ))
        }
        return Array(result.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(maxSessions))
    }

    private static func codexSessionID(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.split(separator: "-").suffix(5).map(String.init).joined(separator: "-").nilIfEmpty
    }

    private static func parseCodexMetadata(from url: URL) -> CodexTranscriptMetadata {
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

        return CodexTranscriptMetadata(
            cwd: cwd,
            createdAt: createdAt,
            promptTitle: titleTracker.resolvedTitle,
            segmentTitle: titleTracker.segmentTitle,
            segmentWasCleared: titleTracker.segmentWasCleared
        )
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

    static func readLinePrefix(from url: URL, maxLines: Int, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        var data = Data()
        var newlineCount = 0
        while data.count < maxBytes, newlineCount < maxLines {
            let chunk = handle.readData(ofLength: min(64 * 1024, maxBytes - data.count))
            if chunk.isEmpty { break }
            newlineCount += chunk.withUnsafeBytes { bytes in
                bytes.reduce(0) { count, byte in count + (byte == 0x0A ? 1 : 0) }
            }
            data.append(chunk)
        }

        return jsonLines(in: data, maxLines: maxLines, takeSuffix: false)
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
        return jsonLines(in: data, maxLines: maxLines, takeSuffix: true, dropFirstLine: offset > 0)
    }

    /// JSONL records are separated by ASCII LF. Scan bytes before decoding:
    /// splitting a multi-megabyte Swift String walks Unicode graphemes across
    /// every record, even though only a few lines at either end are retained.
    /// A suffix read can start inside a UTF-8 scalar, so discard its first
    /// partial record before decoding any selected lines.
    private static func jsonLines(
        in data: Data,
        maxLines: Int,
        takeSuffix: Bool,
        dropFirstLine: Bool = false
    ) -> [String] {
        guard maxLines > 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            var ranges: [Range<Int>] = []
            var lineStart = 0
            for index in bytes.indices where bytes[index] == 0x0A {
                if index > lineStart {
                    ranges.append(lineStart..<index)
                }
                lineStart = index + 1
            }
            if lineStart < bytes.count {
                ranges.append(lineStart..<bytes.count)
            }
            if dropFirstLine, !ranges.isEmpty {
                ranges.removeFirst()
            }
            let selected = takeSuffix ? ranges.suffix(maxLines) : ranges.prefix(maxLines)
            return selected.compactMap { String(bytes: bytes[$0], encoding: .utf8) }
        }
    }

    static func jsonObject(from line: String) -> [String: Any]? {
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
    let fileSize: Int?
}

private struct CodexSessionCandidate {
    let id: String
    let transcriptURL: URL
    let threadName: String?
    let updatedAt: Date
    let modifiedAt: Date
    let fileSize: Int?
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
