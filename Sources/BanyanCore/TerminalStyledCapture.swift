import Foundation

/// A `tmux capture-pane -e` capture reduced to plain rows, with a second copy
/// of each row that keeps only the characters drawn at normal intensity.
///
/// Agents draw placeholders and prompt suggestions faint (SGR 2) inside an
/// otherwise empty input box. Plain captures cannot tell that ghost text from a
/// typed draft; the solid copy can. A capture without escape sequences reads as
/// entirely solid, so callers that only have plain text stay conservative.
public struct TerminalStyledCapture: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let text: String
        /// `text` without the faint characters.
        public let solidText: String
    }

    public let rows: [Row]

    public init(_ capture: String) {
        var rows: [Row] = []
        var text = String.UnicodeScalarView()
        var solid = String.UnicodeScalarView()
        var faint = false
        var scalars = capture.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\n":
                rows.append(Row(text: String(text), solidText: String(solid)))
                text.removeAll(keepingCapacity: true)
                solid.removeAll(keepingCapacity: true)
            case "\u{1B}":
                Self.consumeEscape(&scalars, faint: &faint)
            default:
                text.append(scalar)
                if !faint { solid.append(scalar) }
            }
        }
        rows.append(Row(text: String(text), solidText: String(solid)))
        self.rows = rows
    }

    /// Tracks only intensity. tmux carries attributes across rows, so the state
    /// lives for the whole capture rather than resetting per line.
    private static func consumeEscape(_ scalars: inout Substring.UnicodeScalarView, faint: inout Bool) {
        guard let kind = scalars.popFirst() else { return }
        switch kind {
        case "[":
            var parameters = ""
            while let scalar = scalars.popFirst() {
                if (0x40...0x7E).contains(scalar.value) {
                    if scalar == "m" { applySGR(parameters, faint: &faint) }
                    return
                }
                parameters.unicodeScalars.append(scalar)
            }
        case "]":
            // OSC (hyperlinks): ends at BEL or ST (ESC \).
            while let scalar = scalars.popFirst() {
                if scalar == "\u{07}" { return }
                if scalar == "\u{1B}" { _ = scalars.popFirst(); return }
            }
        default:
            return
        }
    }

    private static func applySGR(_ parameters: String, faint: inout Bool) {
        let tokens = parameters.split(separator: ";", omittingEmptySubsequences: false)
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = tokens[index]
            index += 1
            // Colon sub-parameters (38:2::r:g:b) are one self-contained token.
            if token.contains(":") { continue }
            switch Int(token) ?? 0 {
            case 0, 22: faint = false
            case 2: faint = true
            case 38, 48, 58:
                // Extended colors consume their arguments, which may contain a 2.
                guard index < tokens.endIndex else { return }
                index += tokens[index] == "5" ? 2 : tokens[index] == "2" ? 4 : 1
            default: break
            }
        }
    }
}
