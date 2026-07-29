import Foundation

/// Normalization and input interpretation shared by terminal frontends.
public enum SessionInputPolicy {
    public static func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    public static func normalizedTitleURL(_ titleURL: String?) -> String? {
        normalizedOptionalText(titleURL)
    }

    public static func normalizedDirectory(_ directory: String?) -> String? {
        guard let rawDirectory = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawDirectory.isEmpty else {
            return nil
        }
        let path: String
        if rawDirectory.hasPrefix("file://"), let url = URL(string: rawDirectory), url.isFileURL {
            path = url.path
        } else {
            path = NSString(string: rawDirectory).expandingTildeInPath
        }
        return PathDisplayName.canonicalPath(path)
    }

    public static func isConversationResetCommand(_ input: String?) -> Bool {
        let normalized = input?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "/clear" || normalized == "/new"
    }

    public static func statusAfterSubmittedInput(
        isImportedHistory: Bool,
        isProcessStarted: Bool,
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> SessionStatus? {
        guard !isImportedHistory,
              isProcessStarted,
              status != .closed,
              provider != nil,
              [.running, .longRunningShell, .needInput, .asking].contains(status) else {
            return nil
        }
        return .executing
    }

    public static func submittedPromptTitle(from input: String?) -> String? {
        guard let rawInput = input?.trimmingCharacters(in: .whitespacesAndNewlines), !rawInput.isEmpty else {
            return nil
        }
        guard !rawInput.hasPrefix("/") else { return nil }
        guard let title = SessionTitleGenerator.titleFromPrompt(rawInput) else { return nil }
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trivialResponses: Set<String> = ["c", "continue", "exit", "n", "no", "ok", "okay", "q", "quit", "y", "yes"]
        guard !trivialResponses.contains(normalized) else { return nil }
        guard title.contains(where: \.isLetter), title.count >= 4 else { return nil }
        return title
    }

    public static func titleTracksCurrentDirectory(
        _ title: String,
        isTitlePinned: Bool,
        cwd: String,
        homeDirectory: String
    ) -> Bool {
        guard !isTitlePinned else { return false }
        let currentTitle = SessionTitleGenerator.sanitizeTitle(title)
        let directoryTitle = SessionTitleGenerator.sanitizeTitle(
            PathDisplayName.make(path: cwd, homeDirectory: homeDirectory)
        )
        return currentTitle == directoryTitle
    }
}
