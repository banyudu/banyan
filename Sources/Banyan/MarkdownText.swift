import SwiftUI

struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    let style: MarkdownTextStyle
    let onToggleTask: ((Int) -> Void)?

    init(_ value: String, style: MarkdownTextStyle = .body, onToggleTask: ((Int) -> Void)? = nil) {
        self.blocks = MarkdownBlockParser.parse(value)
        self.style = style
        self.onToggleTask = onToggleTask
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.content {
        case let .heading(level, text):
            inlineText(text)
                .font(style.headingFont(level: level))
                .padding(.top, headingTopPadding(level: level))
        case let .paragraph(text):
            inlineText(text)
                .font(style.paragraphFont)
        case let .list(items):
            VStack(alignment: .leading, spacing: style.listSpacing) {
                ForEach(items) { item in
                    listItemView(item)
                }
            }
        case let .table(table):
            tableView(table)
        case let .codeBlock(_, text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(style.codeFont)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func listItemView(_ item: MarkdownListItem) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Color.clear
                .frame(width: CGFloat(item.indentLevel) * 16, height: 1)

            markerView(item)

            inlineText(item.text)
                .font(style.paragraphFont)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tableView(_ table: MarkdownTable) -> some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { index, cell in
                        tableCell(
                            cell,
                            alignment: table.alignments[index],
                            isHeader: true
                        )
                    }
                }

                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            tableCell(
                                cell,
                                alignment: table.alignments[index],
                                isHeader: false
                            )
                        }
                    }
                }
            }
            .font(style.paragraphFont)
            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func tableCell(
        _ value: String,
        alignment: MarkdownTableAlignment,
        isHeader: Bool
    ) -> some View {
        inlineText(value)
            .font(isHeader ? style.paragraphFont.weight(.semibold) : style.paragraphFont)
            .multilineTextAlignment(alignment.textAlignment)
            .frame(minWidth: 96, maxWidth: .infinity, alignment: alignment.swiftUIAlignment)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isHeader ? Color.primary.opacity(0.07) : Color.clear)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 1)
            }
    }

    @ViewBuilder
    private func markerView(_ item: MarkdownListItem) -> some View {
        if let isChecked = item.isChecked {
            if let taskIndex = item.taskIndex, let onToggleTask {
                Button {
                    onToggleTask(taskIndex)
                } label: {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(style.checkboxFont)
                        .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                        .frame(width: 18, alignment: .leading)
                        .padding(.top, 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isChecked ? "Completed" : "Not completed")
            } else {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(style.checkboxFont)
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .frame(width: 18, alignment: .leading)
                    .padding(.top, 1)
            }
        } else {
            Text(item.markerText)
                .font(style.markerFont)
                .foregroundStyle(.secondary)
                .frame(width: item.markerWidth, alignment: .trailing)
        }
    }

    private func inlineText(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: value, options: options) {
            return Text(attributed)
        }
        return Text(value)
    }

    private func headingTopPadding(level: Int) -> CGFloat {
        switch level {
        case 1, 2:
            return style == .comment ? 2 : 6
        default:
            return 2
        }
    }
}

enum MarkdownTextStyle {
    case body
    case comment

    var blockSpacing: CGFloat {
        switch self {
        case .body: return 10
        case .comment: return 6
        }
    }

    var listSpacing: CGFloat {
        switch self {
        case .body: return 5
        case .comment: return 3
        }
    }

    var paragraphFont: Font {
        switch self {
        case .body: return .callout
        case .comment: return .caption
        }
    }

    var markerFont: Font {
        switch self {
        case .body: return .callout
        case .comment: return .caption
        }
    }

    var checkboxFont: Font {
        switch self {
        case .body: return .callout
        case .comment: return .caption
        }
    }

    var codeFont: Font {
        switch self {
        case .body: return .system(.callout, design: .monospaced)
        case .comment: return .system(.caption, design: .monospaced)
        }
    }

    func headingFont(level: Int) -> Font {
        switch self {
        case .body:
            switch level {
            case 1: return .title3.weight(.semibold)
            case 2: return .headline
            default: return .callout.weight(.semibold)
            }
        case .comment:
            return .caption.weight(.semibold)
        }
    }
}

private struct MarkdownBlock: Identifiable {
    let id: Int
    let content: MarkdownBlockContent
}

private enum MarkdownBlockContent {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case table(MarkdownTable)
    case codeBlock(language: String?, text: String)
}

private struct MarkdownTable {
    let headers: [String]
    let rows: [[String]]
    let alignments: [MarkdownTableAlignment]
}

private enum MarkdownTableAlignment {
    case leading
    case center
    case trailing

    var swiftUIAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct MarkdownListItem: Identifiable {
    let id: Int
    let indentLevel: Int
    let marker: MarkdownListMarker
    var text: String
    let isChecked: Bool?
    let taskIndex: Int?

    var markerText: String {
        switch marker {
        case .unordered:
            return "•"
        case let .ordered(number):
            return "\(number)."
        }
    }

    var markerWidth: CGFloat {
        switch marker {
        case .unordered:
            return 18
        case let .ordered(number):
            return number < 10 ? 22 : 30
        }
    }
}

private enum MarkdownListMarker {
    case unordered
    case ordered(Int)
}

enum MarkdownBlockParser {
    static func containsTable(in value: String) -> Bool {
        parse(value).contains { block in
            if case .table = block.content { return true }
            return false
        }
    }

    fileprivate static func parse(_ value: String) -> [MarkdownBlock] {
        let lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MarkdownBlock] = []
        var index = 0
        var nextID = 0
        var nextTaskIndex = 0

        func append(_ content: MarkdownBlockContent) {
            blocks.append(MarkdownBlock(id: nextID, content: content))
            nextID += 1
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                index += 1
                continue
            }

            if let fence = fenceStart(in: line) {
                let parsed = parseCodeBlock(lines: lines, startIndex: index, fence: fence)
                append(.codeBlock(language: parsed.language, text: parsed.text))
                index = parsed.nextIndex
                continue
            }

            if let heading = heading(in: line) {
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let table = parseTable(lines: lines, startIndex: index) {
                append(.table(table.table))
                index = table.nextIndex
                continue
            }

            if listItem(in: line, id: 0) != nil {
                let parsed = parseList(lines: lines, startIndex: index, nextTaskIndex: &nextTaskIndex)
                append(.list(parsed.items))
                index = parsed.nextIndex
                continue
            }

            let parsed = parseParagraph(lines: lines, startIndex: index)
            append(.paragraph(parsed.text))
            index = parsed.nextIndex
        }

        return blocks.isEmpty ? [MarkdownBlock(id: 0, content: .paragraph(value))] : blocks
    }

    private static func parseTable(
        lines: [String],
        startIndex: Int
    ) -> (table: MarkdownTable, nextIndex: Int)? {
        guard startIndex + 1 < lines.count,
              let headers = tableCells(in: lines[startIndex]),
              let separatorCells = tableCells(in: lines[startIndex + 1]),
              headers.count >= 1,
              separatorCells.count == headers.count,
              separatorCells.allSatisfy({ tableAlignment(for: $0) != nil }) else {
            return nil
        }

        let alignments = separatorCells.map { tableAlignment(for: $0)! }
        var rows: [[String]] = []
        var index = startIndex + 2
        while index < lines.count {
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cells = tableCells(in: line) else {
                break
            }
            rows.append(normalizeTableRow(cells, columnCount: headers.count))
            index += 1
        }

        return (
            MarkdownTable(
                headers: headers,
                rows: rows,
                alignments: alignments
            ),
            index
        )
    }

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in trimmed {
            if character == "|", !isEscaped {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            if character == "|", isEscaped {
                if current.last == "\\" {
                    current.removeLast()
                }
                current.append("|")
                isEscaped = false
                continue
            }
            current.append(character)
            isEscaped = character == "\\"
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignment(for separator: String) -> MarkdownTableAlignment? {
        let value = separator.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let hasLeadingColon = value.first == ":"
        let hasTrailingColon = value.last == ":"
        let dashStart = value.index(value.startIndex, offsetBy: hasLeadingColon ? 1 : 0)
        let dashEnd = value.index(value.endIndex, offsetBy: hasTrailingColon ? -1 : 0)
        guard dashStart < dashEnd,
              !value[dashStart..<dashEnd].isEmpty,
              value[dashStart..<dashEnd].allSatisfy({ $0 == "-" }) else {
            return nil
        }
        switch (hasLeadingColon, hasTrailingColon) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private static func normalizeTableRow(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount { return cells }
        if cells.count < columnCount {
            return cells + Array(repeating: "", count: columnCount - cells.count)
        }
        return Array(cells.prefix(columnCount - 1)) + [cells[(columnCount - 1)...].joined(separator: " | ")]
    }

    private static func parseCodeBlock(
        lines: [String],
        startIndex: Int,
        fence: (delimiter: String, language: String?)
    ) -> (language: String?, text: String, nextIndex: Int) {
        var codeLines: [String] = []
        var index = startIndex + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence.delimiter) {
                return (fence.language, codeLines.joined(separator: "\n"), index + 1)
            }
            codeLines.append(lines[index])
            index += 1
        }
        return (fence.language, codeLines.joined(separator: "\n"), index)
    }

    private static func parseList(
        lines: [String],
        startIndex: Int,
        nextTaskIndex: inout Int
    ) -> (items: [MarkdownListItem], nextIndex: Int) {
        var items: [MarkdownListItem] = []
        var index = startIndex
        var itemID = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                index += 1
                break
            }

            if let item = listItem(in: line, id: itemID, taskIndex: nextTaskIndex) {
                items.append(item)
                itemID += 1
                if item.isChecked != nil { nextTaskIndex += 1 }
                index += 1
                continue
            }

            if fenceStart(in: line) != nil || heading(in: line) != nil {
                break
            }

            if !items.isEmpty {
                items[items.count - 1].text += "\n" + trimmed
                index += 1
            } else {
                break
            }
        }

        return (items, index)
    }

    private static func parseParagraph(
        lines: [String],
        startIndex: Int
    ) -> (text: String, nextIndex: Int) {
        var paragraphLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                break
            }
            if !paragraphLines.isEmpty,
               (fenceStart(in: line) != nil
                || heading(in: line) != nil
                || listItem(in: line, id: 0) != nil
                || parseTable(lines: lines, startIndex: index) != nil) {
                break
            }

            paragraphLines.append(line)
            index += 1
        }

        return (paragraphLines.joined(separator: "\n"), index)
    }

    private static func fenceStart(in line: String) -> (delimiter: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for delimiter in ["```", "~~~"] where trimmed.hasPrefix(delimiter) {
            let language = trimmed.dropFirst(delimiter.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (delimiter, language.isEmpty ? nil : language)
        }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        for character in trimmed {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }
        guard (1...6).contains(level) else { return nil }
        let markerEnd = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd].isWhitespace else { return nil }
        let text = trimmed[markerEnd...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func listItem(in line: String, id: Int, taskIndex: Int? = nil) -> MarkdownListItem? {
        let leadingWidth = leadingWhitespaceWidth(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let unordered = unorderedListItem(in: trimmed, id: id, leadingWidth: leadingWidth, taskIndex: taskIndex) {
            return unordered
        }
        return orderedListItem(in: trimmed, id: id, leadingWidth: leadingWidth, taskIndex: taskIndex)
    }

    private static func unorderedListItem(
        in trimmed: String,
        id: Int,
        leadingWidth: Int,
        taskIndex: Int?
    ) -> MarkdownListItem? {
        guard let marker = trimmed.first,
              ["-", "*", "+"].contains(marker) else {
            return nil
        }
        let afterMarker = trimmed.index(after: trimmed.startIndex)
        guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else {
            return nil
        }
        let rawText = trimmed[afterMarker...].trimmingCharacters(in: .whitespaces)
        let task = taskStateAndText(rawText)
        return MarkdownListItem(
            id: id,
            indentLevel: min(leadingWidth / 2, 4),
            marker: .unordered,
            text: task.text,
            isChecked: task.state,
            taskIndex: task.state == nil ? nil : taskIndex
        )
    }

    private static func orderedListItem(
        in trimmed: String,
        id: Int,
        leadingWidth: Int,
        taskIndex: Int?
    ) -> MarkdownListItem? {
        var index = trimmed.startIndex
        var digits = ""
        while index < trimmed.endIndex, trimmed[index].isNumber {
            digits.append(trimmed[index])
            index = trimmed.index(after: index)
        }
        guard !digits.isEmpty,
              index < trimmed.endIndex,
              trimmed[index] == "." || trimmed[index] == ")" else {
            return nil
        }
        index = trimmed.index(after: index)
        guard index < trimmed.endIndex, trimmed[index].isWhitespace else {
            return nil
        }
        let rawText = trimmed[index...].trimmingCharacters(in: .whitespaces)
        let task = taskStateAndText(rawText)
        return MarkdownListItem(
            id: id,
            indentLevel: min(leadingWidth / 2, 4),
            marker: .ordered(Int(digits) ?? 1),
            text: task.text,
            isChecked: task.state,
            taskIndex: task.state == nil ? nil : taskIndex
        )
    }

    private static func taskStateAndText(_ value: String) -> (state: Bool?, text: String) {
        guard value.count >= 3,
              value.first == "[",
              let closing = value.dropFirst().firstIndex(of: "]") else {
            return (nil, value)
        }
        let marker = value[value.index(after: value.startIndex)..<closing]
        guard marker == " " || marker.lowercased() == "x" else {
            return (nil, value)
        }
        let textStart = value.index(after: closing)
        let text = value[textStart...].trimmingCharacters(in: .whitespaces)
        return (marker.lowercased() == "x", text)
    }

    private static func leadingWhitespaceWidth(in line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " {
                width += 1
            } else if character == "\t" {
                width += 4
            } else {
                break
            }
        }
        return width
    }
}

/// Toggles one Markdown task-list marker without reserializing the description.
/// All whitespace, line endings, indentation, ordering, and unrelated content
/// remain exactly as supplied by Linear.
enum MarkdownTaskListEditor {
    static func toggledDescription(_ value: String, taskIndex: Int) -> String? {
        var lines = value.components(separatedBy: "\n")
        var completedTaskCount = 0
        var fenceDelimiter: String?

        for index in lines.indices {
            let line = lines[index]
            if let fence = fenceStart(in: line) {
                if fenceDelimiter == nil { fenceDelimiter = fence }
                else if fenceDelimiter == fence { fenceDelimiter = nil }
                continue
            }
            guard fenceDelimiter == nil, let markerRange = taskMarkerRange(in: line) else { continue }
            if completedTaskCount == taskIndex {
                let state = line[markerRange].lowercased() == "x" ? " " : "x"
                lines[index].replaceSubrange(markerRange, with: state)
                return lines.joined(separator: "\n")
            }
            completedTaskCount += 1
        }
        return nil
    }

    private static func fenceStart(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static let taskMarkerRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*+]|\d+[.)])\s+\[([ xX])\]"#
    )

    private static func taskMarkerRange(in line: String) -> Range<String.Index>? {
        guard let match = taskMarkerRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return range
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0 else {
            return CGSize(width: 0, height: 0)
        }
        let rows = rows(in: width, subviews: subviews)
        return CGSize(width: width, height: rows.last.map { $0.maxY } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in rows(in: bounds.width, subviews: subviews) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size)
                )
            }
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var currentItems: [FlowItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if currentX > 0, currentX + size.width > width {
                rows.append(FlowRow(y: currentY, height: currentHeight, items: currentItems))
                currentY += currentHeight + spacing
                currentItems = []
                currentX = 0
                currentHeight = 0
            }

            currentItems.append(FlowItem(index: index, x: currentX, size: size))
            currentX += size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(FlowRow(y: currentY, height: currentHeight, items: currentItems))
        }
        return rows
    }

    private struct FlowRow {
        let y: CGFloat
        let height: CGFloat
        let items: [FlowItem]

        var maxY: CGFloat {
            y + height
        }
    }

    private struct FlowItem {
        let index: Int
        let x: CGFloat
        let size: CGSize
    }
}

extension LinearIssueLoadState {
    var isBusy: Bool {
        switch self {
        case .loading, .updating, .updatingDescription:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }
}

extension Color {
    static func linearHex(_ value: String?) -> Color {
        guard let value else { return .secondary }
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let raw = Int(hex, radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((raw >> 16) & 0xff) / 255,
            green: Double((raw >> 8) & 0xff) / 255,
            blue: Double(raw & 0xff) / 255
        )
    }
}
