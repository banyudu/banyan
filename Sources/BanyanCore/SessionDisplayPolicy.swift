import Foundation

/// Presentation-independent session identity and title precedence rules.
public enum SessionDisplayPolicy {
    public static func agentProvider(
        command: String,
        detectedProvider: CodingAgentProvider?
    ) -> CodingAgentProvider? {
        CodingAgentProvider.detect(in: command) ?? detectedProvider
    }

    public static func displayAgentProvider(
        status: SessionStatus,
        command: String,
        detectedProvider: CodingAgentProvider?
    ) -> CodingAgentProvider? {
        if status == .running, CodingAgentProvider.detect(in: command) != nil {
            return nil
        }
        return agentProvider(command: command, detectedProvider: detectedProvider)
    }

    public static func displayTitle(
        title: String,
        isTitlePinned: Bool,
        reportedTitle: String?,
        generatedTitle: String?,
        cwd: String,
        homeDirectory: String,
        detectedProvider: CodingAgentProvider?,
        command: String
    ) -> String {
        if hasUsefulPinnedTitle(
            title: title,
            isTitlePinned: isTitlePinned,
            cwd: cwd,
            homeDirectory: homeDirectory
        ) {
            return title
        }

        if agentProvider(command: command, detectedProvider: detectedProvider) != nil,
           let reportedTitle = usefulAgentTitle(reportedTitle) {
            return reportedTitle
        }

        if let generatedTitle = generatedTitle.flatMap(SessionTitleGenerator.sanitizeTitle) {
            return generatedTitle
        }
        return title
    }

    public static func hasUsefulPinnedTitle(
        title: String,
        isTitlePinned: Bool,
        cwd: String,
        homeDirectory: String
    ) -> Bool {
        guard isTitlePinned else { return false }
        let cleanedTitle = SessionTitleGenerator.sanitizeTitle(title) ?? ""
        guard SessionTitleGenerator.isUsefulTitle(cleanedTitle) else { return false }
        return cleanedTitle != PathDisplayName.make(path: cwd, homeDirectory: homeDirectory)
    }

    public static func usefulAgentTitle(_ title: String?) -> String? {
        guard let value = title.flatMap(SessionTitleGenerator.sanitizeTitle), !value.isEmpty else {
            return nil
        }
        return SessionTitleGenerator.isUsefulTitle(value) ? value : nil
    }
}
