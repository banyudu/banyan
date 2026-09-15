import Foundation

/// One selectable answer in an agent's blocking prompt.
public struct AgentPromptOption: Sendable, Equatable, Codable {
    /// 1-based position in the rendered list.
    public let index: Int
    public let label: String
    /// True when the agent rendered its own `N.` prefix, so the digit key selects
    /// this row directly. Arrow navigation works whether or not a picker binds
    /// digits, so this is only ever an optimization — never the reason an option
    /// is offered.
    public let acceptsNumberKey: Bool

    public init(index: Int, label: String, acceptsNumberKey: Bool) {
        self.index = index
        self.label = label
        self.acceptsNumberKey = acceptsNumberKey
    }
}

/// A question an agent is blocked on, as rendered in its pane.
public struct AgentPrompt: Sendable, Equatable, Codable {
    public let question: String
    /// Lines rendered above the question. For a permission dialog this is the
    /// command or diff being approved, which is the part a remote answerer most
    /// needs to see — "Do you want to proceed?" is identical for every command.
    /// It is part of `footprint` for the same reason.
    public let context: [String]
    public let options: [AgentPromptOption]
    /// 1-based row the selection cursor currently sits on. Defaults to the first
    /// row when the agent draws no cursor.
    public let selectedIndex: Int
    /// Stable digest of question + context + option labels. Recomputing it from a
    /// fresh capture is how an answer proves it is still answering the prompt the
    /// caller was shown. Deliberately excludes the cursor position, which moves as
    /// the answer itself navigates.
    public let footprint: String

    public init(
        question: String,
        context: [String],
        options: [AgentPromptOption],
        selectedIndex: Int,
        footprint: String
    ) {
        self.question = question
        self.context = context
        self.options = options
        self.selectedIndex = selectedIndex
        self.footprint = footprint
    }
}

/// Reads an agent's blocking question out of captured pane text.
///
/// Pure by design: it sees only text, never tmux or the process table. Whether a
/// session is *actually* blocked is `AgentSupervisor`'s job, and a caller must
/// consult it before offering any of these options to a human — text alone cannot
/// tell a live dialog from one that scrolled past.
///
/// The parser is deliberately quick to give up. A mis-read option label selects
/// the wrong entry in a permission dialog, so every ambiguous shape returns `nil`
/// and leaves the caller to show the raw capture with no options at all.
public enum AgentPromptParser {
    /// How far up the capture a dialog is looked for. Matches the supervisor's own
    /// capture window, so both reason about the same region of the pane.
    public static let scanLineLimit = 60

    public static func parse(visibleText: String) -> AgentPrompt? {
        let lines = visibleText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripBorders(String($0)) }
        guard !lines.isEmpty else { return nil }

        let scanStart = max(0, lines.count - scanLineLimit)
        guard let block = optionBlock(in: lines, from: scanStart) else { return nil }

        let rows = block.map { lines[$0] }
        let options = parseOptions(rows)
        guard options.count >= 2 else { return nil }
        let isNumbered = options.allSatisfy(\.acceptsNumberKey)

        guard let heading = heading(
            above: block.lowerBound,
            in: lines,
            from: scanStart,
            allowingMissingQuestionMark: isNumbered
        ) else {
            return nil
        }

        let cursorOffset = rows.firstIndex(where: { hasCursor($0) }) ?? 0
        return AgentPrompt(
            question: heading.question,
            context: heading.context,
            options: options,
            selectedIndex: cursorOffset + 1,
            footprint: footprint(
                question: heading.question,
                context: heading.context,
                options: options
            )
        )
    }

    // MARK: - Option block

    /// Glyphs an agent draws to mark the highlighted row. Kept to the arrow-like
    /// forms the TUIs actually use: a bare `>` is a shell prompt far more often
    /// than it is a selection cursor.
    private static let cursorGlyphs: Set<Character> = ["❯", "›", "❱", "▸", "▶"]
    private static let bulletGlyphs: Set<Character> = ["-", "*", "•"]
    private static let boxDrawingCharacters = Set("─│╭╮╰╯┌┐└┘├┤┬┴┼━┄┈╌═↯┃╹▀▄")

    /// Locates the run of rows that make up one selection list.
    ///
    /// Anchored on the *column the labels start at* rather than on a per-row
    /// marker, because only the highlighted row carries a glyph — Claude's trust
    /// dialog renders `❯ No, exit` above a bare `  Yes, I trust this folder`, and a
    /// marker-per-row rule sees a list of one. Alignment is what a human reads as
    /// "these belong together", and it is what survives both the numbered
    /// (`❯ 1. Yes`) and unnumbered forms.
    private static func optionBlock(in lines: [String], from scanStart: Int) -> Range<Int>? {
        if let anchor = lastCursorRow(in: lines, from: scanStart) {
            return expandBlock(around: anchor.index, labelColumn: anchor.labelColumn, in: lines, from: scanStart)
        }
        // No cursor anywhere: fall back to a plain bullet list, which needs the
        // question mark below to be trusted at all.
        guard let anchor = lastBulletRow(in: lines, from: scanStart) else { return nil }
        return expandBlock(around: anchor.index, labelColumn: anchor.labelColumn, in: lines, from: scanStart)
    }

    private static func lastCursorRow(in lines: [String], from scanStart: Int) -> (index: Int, labelColumn: Int)? {
        for index in stride(from: lines.count - 1, through: scanStart, by: -1) {
            guard let column = labelColumn(ofCursorRow: lines[index]) else { continue }
            return (index, column)
        }
        return nil
    }

    private static func lastBulletRow(in lines: [String], from scanStart: Int) -> (index: Int, labelColumn: Int)? {
        for index in stride(from: lines.count - 1, through: scanStart, by: -1) {
            let line = lines[index]
            let indent = leadingSpaces(in: line)
            guard indent < line.count else { continue }
            let marker = line[line.index(line.startIndex, offsetBy: indent)]
            guard bulletGlyphs.contains(marker) else { continue }
            guard let column = labelColumn(after: indent + 1, in: line) else { continue }
            return (index, column)
        }
        return nil
    }

    /// The column a cursor row's label starts at, or nil when the row is not a
    /// usable option: a bare `❯` input row, or one holding a slash command the
    /// user typed rather than an answer the agent offered.
    private static func labelColumn(ofCursorRow line: String) -> Int? {
        let indent = leadingSpaces(in: line)
        guard indent < line.count else { return nil }
        guard cursorGlyphs.contains(line[line.index(line.startIndex, offsetBy: indent)]) else { return nil }
        guard let column = labelColumn(after: indent + 1, in: line) else { return nil }
        return column
    }

    private static func labelColumn(after markerIndex: Int, in line: String) -> Int? {
        var column = markerIndex
        let characters = Array(line)
        while column < characters.count, characters[column] == " " {
            column += 1
        }
        guard column > markerIndex, column < characters.count else { return nil }
        let label = String(characters[column...])
        guard !label.hasPrefix("/") else { return nil }
        return column
    }

    /// Grows the block over the contiguous non-blank rows whose text starts at the
    /// anchor's label column. A blank row, a divider, or a row at any other indent
    /// ends the list — which is what keeps the footer (`Esc to cancel`) and the
    /// question above it out of the options.
    private static func expandBlock(
        around anchor: Int,
        labelColumn column: Int,
        in lines: [String],
        from scanStart: Int
    ) -> Range<Int> {
        var start = anchor
        while start - 1 >= scanStart, isBlockRow(lines[start - 1], at: column) {
            start -= 1
        }
        var end = anchor
        while end + 1 < lines.count, isBlockRow(lines[end + 1], at: column) {
            end += 1
        }
        return start..<(end + 1)
    }

    private static func isBlockRow(_ line: String, at column: Int) -> Bool {
        if isBlank(line) || isDividerOnly(line) { return false }
        if let cursorColumn = labelColumn(ofCursorRow: line) { return cursorColumn == column }
        return leadingSpaces(in: line) == column
    }

    private static func parseOptions(_ rows: [String]) -> [AgentPromptOption] {
        var options: [AgentPromptOption] = []
        for (offset, row) in rows.enumerated() {
            let text = strippedMarker(row)
            guard !text.isEmpty else { return [] }
            let index = offset + 1
            if let numbered = numberedLabel(text), numbered.number == index {
                options.append(AgentPromptOption(index: index, label: numbered.label, acceptsNumberKey: true))
            } else {
                options.append(AgentPromptOption(index: index, label: text, acceptsNumberKey: false))
            }
        }
        // A list that numbers only some of its rows is a list we misread.
        let numberedCount = options.filter(\.acceptsNumberKey).count
        guard numberedCount == 0 || numberedCount == options.count else { return [] }
        return options
    }

    /// Splits a leading `1.` / `1)` off a row. Bounded to two digits so a row that
    /// merely opens with a year or a byte count is not mistaken for a menu entry.
    private static func numberedLabel(_ text: String) -> (number: Int, label: String)? {
        var digits = ""
        var index = text.startIndex
        while index < text.endIndex, text[index].isNumber, digits.count < 2 {
            digits.append(text[index])
            index = text.index(after: index)
        }
        guard let number = Int(digits), number >= 1, index < text.endIndex else { return nil }
        guard text[index] == "." || text[index] == ")" else { return nil }
        let label = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label)
    }

    private static func strippedMarker(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "" }
        if cursorGlyphs.contains(first) || bulletGlyphs.contains(first) {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    private static func hasCursor(_ line: String) -> Bool {
        guard let first = line.trimmingCharacters(in: .whitespaces).first else { return false }
        return cursorGlyphs.contains(first)
    }

    // MARK: - Question

    /// How far above the options a heading is looked for, and how much of it is
    /// kept. Both are small on purpose: a wide window starts pulling unrelated
    /// transcript into the text a human is asked to approve.
    private static let headingWindow = 14
    private static let maxContextLines = 8
    private static let maxFallbackParagraphs = 2
    private static let maxFallbackLines = 6

    private static func heading(
        above blockStart: Int,
        in lines: [String],
        from scanStart: Int,
        allowingMissingQuestionMark: Bool
    ) -> (question: String, context: [String])? {
        let windowStart = max(scanStart, blockStart - headingWindow)
        guard windowStart < blockStart else { return nil }
        let paragraphs = paragraphs(in: Array(lines[windowStart..<blockStart]))
        guard !paragraphs.isEmpty else { return nil }

        if let questionIndex = paragraphs.lastIndex(where: { $0.contains(where: { $0.contains("?") }) }) {
            let question = paragraphs[questionIndex].joined(separator: " ")
            let context = paragraphs[..<questionIndex]
                .flatMap(\.self)
                .suffix(maxContextLines)
            return (question, Array(context))
        }

        // A numbered list is unambiguous on its own, so it is still offered when
        // the agent phrased its heading as a statement ("Update available!").
        // Anything weaker has to show a question mark or it gets no options.
        guard allowingMissingQuestionMark else { return nil }
        let fallback = paragraphs
            .suffix(maxFallbackParagraphs)
            .flatMap(\.self)
            .suffix(maxFallbackLines)
        guard !fallback.isEmpty else { return nil }
        return (fallback.joined(separator: "\n"), [])
    }

    /// Groups the heading window into blank-line- and rule-delimited paragraphs,
    /// each already trimmed. Dividers split as hard as blanks do: Claude draws one
    /// between the transcript and the dialog it is asking about.
    private static func paragraphs(in lines: [String]) -> [[String]] {
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            if isBlank(line) || isDividerOnly(line) {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
                continue
            }
            current.append(line.trimmingCharacters(in: .whitespaces))
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    // MARK: - Footprint

    /// Digests the prompt into a value an answer can be checked against. Not a
    /// security primitive and not trying to be: it guards one local pane against
    /// having moved on, and anyone who can choose the text in that pane can
    /// already type into it. A 128-bit FNV-1a keeps accidental collisions out of
    /// reach without a dependency CryptoKit cannot supply on Linux.
    private static func footprint(
        question: String,
        context: [String],
        options: [AgentPromptOption]
    ) -> String {
        let canonical = ([question] + context + options.map { "\($0.index). \($0.label)" })
            .map(collapseWhitespace)
            .joined(separator: "\n")
        return fnv1a128Hex(canonical)
    }

    /// Absorbs the padding tmux reports at a pane's rendered width, so the same
    /// dialog digests identically after a resize.
    private static func collapseWhitespace(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fnv1a128Hex(_ text: String) -> String {
        let bytes = Array(text.utf8)
        // Two FNV-1a 64 runs seeded differently. Independent seeds are what make
        // the concatenation worth 128 bits rather than 64 bits written twice.
        let high = fnv1a64(bytes, offsetBasis: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a64(bytes, offsetBasis: 0x9dd3_9a4a_7c63_1c7d)
        return hex(high) + hex(low)
    }

    private static func fnv1a64(_ bytes: [UInt8], offsetBasis: UInt64) -> UInt64 {
        var hash = offsetBasis
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    // MARK: - Line normalization

    /// Strips the frame an agent draws around a dialog so the text inside lines up
    /// with text that was never boxed. Leading spaces are preserved because the
    /// option block is found by alignment.
    private static func stripBorders(_ line: String) -> String {
        var text = line
        if text.hasSuffix("\r") {
            text.removeLast()
        }
        var characters = Array(text)
        while let last = characters.last, last == " " || boxDrawingCharacters.contains(last) {
            characters.removeLast()
        }
        var start = 0
        while start < characters.count, boxDrawingCharacters.contains(characters[start]) {
            start += 1
        }
        // Replace the border with a space so the column the text starts at is the
        // column the agent rendered it at.
        if start > 0 {
            return String(repeating: " ", count: start) + String(characters[start...])
        }
        return String(characters)
    }

    private static func leadingSpaces(in line: String) -> Int {
        var count = 0
        for character in line {
            guard character == " " else { break }
            count += 1
        }
        return count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func isDividerOnly(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { boxDrawingCharacters.contains($0) || $0 == " " }
    }
}

/// The rule that decides whether a parsed prompt may be shown to a human at all.
///
/// Kept apart from the parser because it is a different claim. The parser answers
/// "does this text look like a list of answers"; this answers "is the session
/// actually blocked on it right now". Text alone cannot tell a live dialog from
/// one three `/clear`s back, so both have to agree before any option is offered.
public enum AgentPromptGate {
    /// - Parameters:
    ///   - status: the supervisor's verdict, not the session's persisted status.
    ///   - classifiedText: the capture that verdict was made from. A different
    ///     capture — even one taken a moment later — is not evidence about this
    ///     verdict, so passing one would defeat the gate.
    public static func prompt(status: SessionStatus, classifiedText: String?) -> AgentPrompt? {
        guard status.isAwaitingHumanAnswer, let classifiedText else { return nil }
        return AgentPromptParser.parse(visibleText: classifiedText)
    }
}
