import Foundation

/// Text cleanup shared by everything that shells out to a CLI.
///
/// This lived as two byte-identical private copies — one in `SessionContextResolver`,
/// one in `LinearIssueClient` — which is why a single bad pattern had to be fixed in
/// two places, and why it went unnoticed in both.
public enum CommandOutputText {
    /// Matches a CSI escape sequence: ESC `[`, parameter bytes, intermediate bytes,
    /// then a final byte.
    ///
    /// The ESC is a Swift escape spliced into a normal string rather than written
    /// inside a raw literal. In a raw string Swift leaves `\u{001B}` untouched, ICU
    /// receives those eight characters and rejects the pattern, and the regex never
    /// compiles — which is exactly how this silently stripped nothing for its whole
    /// life, then trapped once it was hoisted behind `try!`.
    static let ansiEscapeRegex = try! NSRegularExpression(
        pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    )

    /// Removes ANSI escape sequences so CLI output can be parsed or displayed.
    public static func strippingANSIEscapes(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return ansiEscapeRegex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
