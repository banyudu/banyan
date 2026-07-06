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
        if let project = sanitizeTitle(context.project), !project.isEmpty {
            components.append(project)
        } else if let cwdTitle = sanitizeTitle(URL(fileURLWithPath: context.cwd).lastPathComponent), !cwdTitle.isEmpty {
            components.append(cwdTitle)
        }
        if let branch = context.branch.flatMap(sanitizeTitle), !branch.isEmpty {
            components.append(branch)
        }
        let id = sanitizeTitle(context.id)
        if let id, !components.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) {
            components.append(id)
        }
        return truncate(components.joined(separator: " · "), limit: 56)
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
        var title = sanitizeTitle(firstSentence(in: prompt)) ?? ""
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
            if let sentenceEnd = line.firstIndex(where: { ".!?。！？".contains($0) }) {
                return String(line[...sentenceEnd])
            }
            return line
        }

        return trimmed
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: max(0, limit - 3))
        return "\(value[..<end])..."
    }
}
