import Foundation

public struct SessionCreationPlan: Sendable, Equatable {
    public let baseID: String
    public let title: String
    public let titleURL: String?
    public let isTitlePinned: Bool
    public let cwd: String
    public let command: String
    public let parentSessionID: String?

    public init(
        baseID: String,
        title: String,
        titleURL: String?,
        isTitlePinned: Bool,
        cwd: String,
        command: String,
        parentSessionID: String?
    ) {
        self.baseID = baseID
        self.title = title
        self.titleURL = titleURL
        self.isTitlePinned = isTitlePinned
        self.cwd = cwd
        self.command = command
        self.parentSessionID = parentSessionID
    }
}

/// Normalizes user input before a frontend constructs a live session model.
public enum SessionCreationPolicy {
    public static func plan(
        proposedID: String?,
        proposedTitle: String?,
        proposedTitleURL: String?,
        proposedCWD: String?,
        proposedCommand: String?,
        proposedParentSessionID: String?,
        currentDirectory: String,
        homeDirectory: String
    ) -> SessionCreationPlan {
        let baseID = SessionIdentityPolicy.sanitizedID(proposedID ?? proposedTitle ?? "session")
        let cwd = WorkingDirectoryPolicy.resolve(
            proposedDirectory: proposedCWD,
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
        let hasExplicitTitle = proposedTitle?.isEmpty == false
        return SessionCreationPlan(
            baseID: baseID,
            title: hasExplicitTitle
                ? proposedTitle!
                : PathDisplayName.make(path: cwd, homeDirectory: homeDirectory),
            titleURL: SessionInputPolicy.normalizedTitleURL(proposedTitleURL),
            isTitlePinned: hasExplicitTitle,
            cwd: cwd,
            command: proposedCommand ?? "",
            parentSessionID: SessionInputPolicy.normalizedOptionalText(proposedParentSessionID)
        )
    }
}
