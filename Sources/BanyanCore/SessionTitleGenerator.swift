import Foundation

public struct SessionTitleContext: Equatable {
    public let id: String
    public let baseTitle: String
    public let isTitlePinned: Bool
    public let cwd: String
    public let project: String
    public let branch: String?
    public let command: String
    public let reportedTitle: String?
    public let provider: CodingAgentProvider?

    public init(
        id: String,
        baseTitle: String,
        isTitlePinned: Bool,
        cwd: String,
        project: String,
        branch: String?,
        command: String,
        reportedTitle: String?,
        provider: CodingAgentProvider?
    ) {
        self.id = id
        self.baseTitle = baseTitle
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.project = project
        self.branch = branch
        self.command = command
        self.reportedTitle = reportedTitle
        self.provider = provider
    }
}

public enum SessionTitleGenerator {
    public static func automaticTitle(for context: SessionTitleContext) -> String? {
        if context.isTitlePinned, let title = sanitizeTitle(context.baseTitle) {
            return title
        }

        if let reportedTitle = context.reportedTitle.flatMap(sanitizeTitle),
           isUsefulTitle(reportedTitle) {
            return reportedTitle
        }

        if let provider = context.provider,
           let prompt = CodingAgentProvider.promptCandidate(in: context.command, provider: provider),
           let promptTitle = titleFromPrompt(prompt) {
            return promptTitle
        }

        if let idTitle = sanitizeTitle(context.id),
           !isGenericTitle(idTitle),
           !looksLikeHostTitle(idTitle) {
            return idTitle
        }

        guard let provider = context.provider else {
            return nil
        }

        var components = [provider.displayName]
        let id = sanitizeTitle(context.id)
        if let id, !components.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            components.append(id)
        }
        return truncate(components.joined(separator: " "), limit: 56)
    }

    public static func sanitizeTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard !cleaned.isEmpty else { return nil }
        return truncate(cleaned, limit: 72)
    }

    public static func isUsefulTitle(_ value: String) -> Bool {
        let title = sanitizeTitle(value) ?? ""
        return !isGenericTitle(title) && !looksLikeHostTitle(title)
    }

    public static func titleFromPrompt(_ prompt: String) -> String? {
        let normalized = normalizePromptForTitle(prompt)
        var title = sanitizeTitle(firstSentence(in: normalized)) ?? ""
        for prefix in ["please ", "can you ", "could you ", "i want to ", "help me "] {
            if title.lowercased().hasPrefix(prefix) {
                title = String(title.dropFirst(prefix.count))
                break
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return truncate(title, limit: 56)
    }

    public static func isGenericTitle(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.isEmpty
            || lowercased == "shell"
            || lowercased.hasPrefix("shell-")
            || lowercased == "session"
            || lowercased.hasPrefix("session-")
            || CodingAgentProvider.allCases.contains { $0.rawValue == lowercased || $0.displayName.lowercased() == lowercased }
    }

    /// Titles produced for sessions that have not received a meaningful name.
    /// This intentionally excludes provider names, which can be useful labels
    /// when restoring a persisted snapshot.
    public static func isGenericDefaultTitle(_ value: String) -> Bool {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercased.isEmpty
            || lowercased == "shell"
            || lowercased.hasPrefix("shell-")
            || lowercased == "session"
            || lowercased.hasPrefix("session-")
    }

    public static func looksLikeHostTitle(_ value: String) -> Bool {
        let parts = value.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        return !parts[0].contains(" ") && !parts[1].contains(" ")
    }

    private static func firstSentence(in prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let firstLine = trimmed.split(whereSeparator: \.isNewline).first {
            let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if let sentenceEnd = findSentenceEnd(in: line) {
                return String(line[...sentenceEnd])
            }
            return line
        }

        return trimmed
    }

    private static func findSentenceEnd(in line: String) -> String.Index? {
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if "!?。！？".contains(ch) {
                return index
            }
            if ch == "." {
                let next = line.index(after: index)
                let followedBySpaceOrEnd = next >= line.endIndex || line[next].isWhitespace
                if followedBySpaceOrEnd && !isInsideNonSentenceToken(line, dotAt: index) {
                    return index
                }
            }
            index = line.index(after: index)
        }
        return nil
    }

    private static func isInsideNonSentenceToken(_ line: String, dotAt: String.Index) -> Bool {
        let before = line[..<dotAt]
        let wordStart = before.lastIndex(where: { $0.isWhitespace })
            .map { line.index(after: $0) } ?? line.startIndex
        let after = line[line.index(after: dotAt)...]
        let wordEnd = after.firstIndex(where: { $0.isWhitespace }) ?? line.endIndex
        let token = String(line[wordStart..<wordEnd])

        if token.contains("://") { return true }

        let dotCount = token.filter { $0 == "." }.count
        if dotCount >= 2 { return true }

        if token.hasSuffix(".") {
            let base = String(token.dropLast())
            let knownExtensions = ["swift", "ts", "js", "py", "go", "rs", "java", "kt",
                                   "rb", "c", "h", "cpp", "cs", "md", "json", "yaml",
                                   "yml", "toml", "xml", "html", "css", "sh", "txt"]
            let ext = base.split(separator: ".").last.map(String.init) ?? ""
            if knownExtensions.contains(ext.lowercased()) { return true }
        }

        return false
    }

    private static func normalizePromptForTitle(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return prompt }
        if isSingleURLPrompt(trimmed) || isSingleImagePrompt(trimmed) {
            return prompt
        }
        var result = prompt
        result = replacingURLs(in: result, with: "<url>")
        result = replacingImagePlaceholders(in: result, with: "<img>")
        return result
    }

    private static func isSingleURLPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^https?://\\S+$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: range) != nil
    }

    private static func isSingleImagePrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePattern = "^\\[Image[^\\]]*\\]$"
        if let regex = try? NSRegularExpression(pattern: imagePattern, options: .caseInsensitive),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        let markdownPattern = "^!\\[.*?\\]\\(.*?\\)$"
        if let regex = try? NSRegularExpression(pattern: markdownPattern, options: []),
           regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return true
        }
        return false
    }

    private static func replacingURLs(in text: String, with placeholder: String) -> String {
        let pattern = "https?://[^\\s]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'")
            var urlPart = matched
            var suffix = ""
            while let last = urlPart.last, String(last).unicodeScalars.allSatisfy({ trailingPunctuation.contains($0) }) {
                suffix = String(last) + suffix
                urlPart.removeLast()
                if urlPart.isEmpty { break }
            }
            if urlPart.isEmpty { continue }
            // Preserve Linear issue IDs that are embedded in the URL so the title
            // still shows the meaningful identifier instead of a generic placeholder.
            let replacement: String
            if let issueID = LinearIssueReference.issueID(in: urlPart) {
                replacement = issueID + suffix
            } else if let githubID = GitHubIssueReference.detect(in: urlPart)?.url {
                // For GitHub URLs keep a short hint – the full URL is rarely
                // useful in a 56-char title. Fall back to generic placeholder.
                _ = githubID
                replacement = placeholder + suffix
            } else {
                replacement = placeholder + suffix
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    private static func replacingImagePlaceholders(in text: String, with placeholder: String) -> String {
        var result = text
        let bracketPattern = "\\[Image[^\\]]*\\]"
        if let regex = try? NSRegularExpression(pattern: bracketPattern, options: .caseInsensitive) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: placeholder)
            }
        }
        let markdownPattern = "!\\[.*?\\]\\(.*?\\)"
        if let regex = try? NSRegularExpression(pattern: markdownPattern, options: []) {
            let ns = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: placeholder)
            }
        }
        return result
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 3))
        return "\(value[..<end])..."
    }
}
