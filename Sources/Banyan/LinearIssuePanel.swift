import AppKit
import SwiftUI

enum LinearIssuePanelPresentation {
    case sidebar
    case main

    var width: CGFloat? {
        switch self {
        case .sidebar:
            return 360
        case .main:
            return nil
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .sidebar:
            return nil
        case .main:
            return .infinity
        }
    }

    var contentMaxWidth: CGFloat? {
        switch self {
        case .sidebar:
            return nil
        case .main:
            return 860
        }
    }
}

struct LinearIssuePanel: View {
    let context: SessionContextInfo
    let issue: LinearIssueDetails?
    let loadState: LinearIssueLoadState
    let onRefresh: () -> Void
    let onOpen: () -> Void
    let onChangeState: (LinearWorkflowState) -> Void
    let onStart: (() -> Void)?
    let isStarting: Bool
    let presentation: LinearIssuePanelPresentation
    @State private var selectedStateID: String?

    init(
        context: SessionContextInfo,
        issue: LinearIssueDetails?,
        loadState: LinearIssueLoadState,
        onRefresh: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onChangeState: @escaping (LinearWorkflowState) -> Void,
        onStart: (() -> Void)? = nil,
        isStarting: Bool = false,
        presentation: LinearIssuePanelPresentation = .sidebar
    ) {
        self.context = context
        self.issue = issue
        self.loadState = loadState
        self.onRefresh = onRefresh
        self.onOpen = onOpen
        self.onChangeState = onChangeState
        self.onStart = onStart
        self.isStarting = isStarting
        self.presentation = presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            content
        }
        .frame(width: presentation.width)
        .frame(maxWidth: presentation.maxWidth, maxHeight: .infinity, alignment: .topLeading)
        .background(panelBackground)
        .accessibilityIdentifier(AccessibilityID.linearIssuePanel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue?.identifier ?? context.linearIssueID ?? "Linear")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let onStart {
                startButton(onStart)
            }

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueRefreshButton)
            .help("Refresh Linear issue")

            Button(action: onOpen) {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.linearIssueOpenButton)
            .help("Open in Linear")
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        switch presentation {
        case .sidebar:
            Rectangle()
                .fill(.regularMaterial)
        case .main:
            Color.clear
        }
    }

    @ViewBuilder
    private func startButton(_ action: @escaping () -> Void) -> some View {
        switch presentation {
        case .sidebar:
            Button(action: action) {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(isStarting)
            .help("Start Banyan session")
        case .main:
            Button(action: action) {
                Label("Start Session", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isStarting)
            .help("Start Banyan session")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle:
            placeholder("No Linear issue")
        case .loading:
            loadingView("Loading issue...")
        case let .updating(stateName):
            loadingView("Moving to \(stateName)...")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                placeholder(message)
                Button("Retry", action: onRefresh)
                    .buttonStyle(.bordered)
            }
            .padding(14)
        case .loaded:
            if let issue {
                issueContent(issue)
            } else {
                placeholder("No issue details")
            }
        }
    }

    private func issueContent(_ issue: LinearIssueDetails) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                metadataGrid(issue)

                if !issue.workflowStates.isEmpty {
                    HStack(spacing: 8) {
                        sectionTitle("Status")
                            .frame(width: 54, alignment: .leading)
                        Picker("Status", selection: statusSelectionBinding(issue)) {
                            ForEach(issue.workflowStates) { state in
                                Label {
                                    Text(state.name)
                                } icon: {
                                    Circle()
                                        .fill(Color.linearHex(state.color))
                                }
                                .tag(state.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .disabled(loadState.isBusy)
                        .help("Change Linear status")
                    }
                }

                if let description = issue.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Description")
                        MarkdownText(description)
                    }
                }

                if !issue.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Labels")
                        FlowLayout(spacing: 6) {
                            ForEach(issue.labels) { label in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(Color.linearHex(label.color))
                                        .frame(width: 6, height: 6)
                                    Text(label.name)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }

                if !issue.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Links")
                        ForEach(issue.attachments) { attachment in
                            Button {
                                if let url = URL(string: attachment.url) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "link")
                                    Text(attachment.title)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if !issue.comments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Recent Comments")
                        ForEach(issue.comments) { comment in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(comment.userName ?? "Unknown")
                                    .font(.caption.weight(.semibold))
                                MarkdownText(comment.body, style: .comment)
                                    .lineLimit(8)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: presentation.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            selectedStateID = issue.state.id
        }
        .onChange(of: issue.state.id) { _, newValue in
            selectedStateID = newValue
        }
    }

    private func statusSelectionBinding(_ issue: LinearIssueDetails) -> Binding<String> {
        Binding {
            selectedStateID ?? issue.state.id
        } set: { newValue in
            selectedStateID = newValue
            guard newValue != issue.state.id,
                  let state = issue.workflowStates.first(where: { $0.id == newValue }) else {
                return
            }
            onChangeState(state)
        }
    }

    private func metadataGrid(_ issue: LinearIssueDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            metadataRow("Assignee", issue.assigneeName)
            metadataRow("Project", issue.projectName)
            metadataRow("Cycle", issue.cycleName)
            metadataRow("Team", issue.teamName)
            if let priority = issue.priority, priority > 0 {
                metadataRow("Priority", "P\(priority)")
            }
            if let estimate = issue.estimate {
                metadataRow("Estimate", "\(estimate)")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .leading)
                Text(value)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func loadingView(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerSubtitle: String {
        switch loadState {
        case .idle:
            return "Not detected"
        case .loading:
            return "Loading"
        case let .updating(stateName):
            return "Moving to \(stateName)"
        case .loaded:
            return issue?.state.name ?? "Loaded"
        case .failed:
            return "Needs Linear auth"
        }
    }
}

private struct MarkdownText: View {
    let blocks: [MarkdownBlock]
    let style: MarkdownTextStyle

    init(_ value: String, style: MarkdownTextStyle = .body) {
        self.blocks = MarkdownBlockParser.parse(value)
        self.style = style
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

    @ViewBuilder
    private func markerView(_ item: MarkdownListItem) -> some View {
        if let isChecked = item.isChecked {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(style.checkboxFont)
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                .frame(width: 18, alignment: .leading)
                .padding(.top, 1)
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

private enum MarkdownTextStyle {
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
    case codeBlock(language: String?, text: String)
}

private struct MarkdownListItem: Identifiable {
    let id: Int
    let indentLevel: Int
    let marker: MarkdownListMarker
    var text: String
    let isChecked: Bool?

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

private enum MarkdownBlockParser {
    static func parse(_ value: String) -> [MarkdownBlock] {
        let lines = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [MarkdownBlock] = []
        var index = 0
        var nextID = 0

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

            if listItem(in: line, id: 0) != nil {
                let parsed = parseList(lines: lines, startIndex: index)
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
        startIndex: Int
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

            if let item = listItem(in: line, id: itemID) {
                items.append(item)
                itemID += 1
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
               (fenceStart(in: line) != nil || heading(in: line) != nil || listItem(in: line, id: 0) != nil) {
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

    private static func listItem(in line: String, id: Int) -> MarkdownListItem? {
        let leadingWidth = leadingWhitespaceWidth(in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if let unordered = unorderedListItem(in: trimmed, id: id, leadingWidth: leadingWidth) {
            return unordered
        }
        return orderedListItem(in: trimmed, id: id, leadingWidth: leadingWidth)
    }

    private static func unorderedListItem(
        in trimmed: String,
        id: Int,
        leadingWidth: Int
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
            isChecked: task.state
        )
    }

    private static func orderedListItem(
        in trimmed: String,
        id: Int,
        leadingWidth: Int
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
            isChecked: task.state
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

private struct FlowLayout: Layout {
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

private extension LinearIssueLoadState {
    var isBusy: Bool {
        switch self {
        case .loading, .updating:
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
