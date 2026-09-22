import Foundation

/// How Banyan runs a command it was asked to run on the user's behalf.
///
/// Shared by `palette_commands:` entries and by inbound `/suggest` payloads: an
/// approved suggestion runs through the palette's own path, so both have to name
/// the same two behaviours rather than keep parallel enums that drift.
/// `PaletteCommand.Parent` stays in the app target — where a session lands in the
/// sidebar tree is a UI notion, and an out-of-process suggester has no business
/// choosing it.
public enum CommandRunMode: String, Codable, Sendable, CaseIterable {
    /// Opens a Banyan session and runs the command in its pane.
    case session
    /// Runs detached, with its output captured to a log file.
    case background
}
