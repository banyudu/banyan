import BanyanCore
import SwiftUI

enum PuckApprovalChoice: String, CaseIterable {
    case approve
    case session
    case deny
    /// Deny, and tell the agent what to do instead.
    case feedback

    var label: String {
        switch self {
        case .approve: "Yes, proceed"
        case .session: "Yes, and don't ask again for this tool in this session"
        case .deny: "No, continue without running it"
        case .feedback: "No, and tell Puck what to do differently"
        }
    }

    /// The letter shortcut Codex uses for the same answer.
    var letter: Character? {
        switch self {
        case .approve: "y"
        case .session: "a"
        case .deny: "n"
        case .feedback: nil
        }
    }
}

/// A pending tool approval. Keys: 1–4 or y/a/n answer, ↑/↓ and Return pick
/// a row, Esc asks for feedback instead.
struct PuckApprovalPanel: View {
    @ObservedObject var session: PuckSession
    let pending: PuckPendingApproval
    let typography: PuckTranscriptTypography
    /// Whether to take keyboard focus when the ask appears. A user who is
    /// typing a message keeps the composer, so a stray key cannot answer.
    let takesFocus: Bool
    @State private var selection: PuckApprovalChoice = .approve
    @State private var feedback = ""
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case choices, feedback }

    var body: some View {
        let presentation = PuckApprovalPresentation(
            pending,
            tools: session.timeline.items.compactMap { item in
                if case .tool(let tool) = item.content { return tool }
                return nil
            },
            workspace: session.cwd
        )
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.callout.weight(.semibold))
                Text([pending.tool, presentation.fileSummary].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let reason = presentation.reason {
                SessionLinkedText(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = presentation.command {
                VStack(alignment: .leading, spacing: 4) {
                    PuckQuietCodePreview(text: "$ " + command, typography: typography,
                                         maximumVisibleLines: 6, maximumHeight: 140)
                    if let directory = presentation.workingDirectory {
                        Text("in \(PuckFileChanges.displayPath(directory, relativeTo: nil))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if let diff = presentation.diff {
                CodeBlockView(
                    text: diff,
                    language: "diff",
                    font: typography.font,
                    previewHeight: min(260, max(60, CGFloat(diff.split(separator: "\n").count) * typography.detailLineHeight + 16)),
                    showsHeader: false,
                    detectsLinks: true
                )
            }
            if let details = presentation.details {
                PuckQuietCodePreview(text: details, typography: typography,
                                     maximumVisibleLines: 6, maximumHeight: 140)
            }
            VStack(spacing: 2) {
                ForEach(Array(PuckApprovalChoice.allCases.enumerated()), id: \.element) { index, choice in
                    choiceRow(choice, number: index + 1)
                }
            }
            if selection == .feedback {
                HStack(spacing: 8) {
                    TextField("Tell Puck what to do differently", text: $feedback, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(typography.font)
                        .lineLimit(1...4)
                        .focused($focus, equals: .feedback)
                        .onSubmit(sendFeedback)
                        .onExitCommand { focus = .choices }
                        .accessibilityIdentifier(AccessibilityID.puckApprovalFeedback)
                    Button("Deny", action: sendFeedback)
                        .buttonStyle(.banyanBorderedProminent)
                        .controlSize(.small)
                }
                .padding(8)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(selection == .feedback
                 ? "Return to deny with this message · Esc to go back to the choices"
                 : "Press 1–4, or y, a, n · Esc to tell Puck what to do differently")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .pendingAskLayout()
        .focusable()
        .focused($focus, equals: .choices)
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handle)
        .onAppear { if takesFocus { focus = .choices } }
        .onChange(of: session.askFocusRequest) { _, _ in focus = .choices }
        .accessibilityIdentifier(AccessibilityID.puckApprovalPanel)
    }

    private func choiceRow(_ choice: PuckApprovalChoice, number: Int) -> some View {
        let isSelected = selection == choice
        return Button {
            activate(choice)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(isSelected ? "›" : " ")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 12, alignment: .leading)
                Text("\(number).")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(choice.label)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                if let letter = choice.letter {
                    Text("(\(String(letter)))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.banyanPlainLabelOnly)
        .onHover { hovering in
            if hovering, selection != .feedback { selection = choice }
        }
        .accessibilityLabel(choice.label)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard focus == .choices,
              press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let choices = PuckApprovalChoice.allCases
        switch press.key {
        case .upArrow:
            if let index = choices.firstIndex(of: selection), index > 0 { selection = choices[index - 1] }
            return .handled
        case .downArrow:
            if let index = choices.firstIndex(of: selection), index < choices.count - 1 { selection = choices[index + 1] }
            return .handled
        case .return:
            activate(selection)
            return .handled
        case .escape:
            activate(.feedback)
            return .handled
        default:
            break
        }
        let character = press.characters.lowercased()
        if let number = Int(character), (1...choices.count).contains(number) {
            activate(choices[number - 1])
            return .handled
        }
        if let choice = choices.first(where: { $0.letter.map(String.init) == character }) {
            activate(choice)
            return .handled
        }
        return .ignored
    }

    private func activate(_ choice: PuckApprovalChoice) {
        selection = choice
        switch choice {
        case .feedback:
            DispatchQueue.main.async { focus = .feedback }
        case .approve, .session, .deny:
            session.decide(choice.rawValue)
        }
    }

    private func sendFeedback() {
        session.denyWithFeedback(feedback)
        feedback = ""
    }
}

/// A short, quiet code excerpt that scrolls when it is long.
struct PuckQuietCodePreview: View {
    let text: String
    let typography: PuckTranscriptTypography
    var maximumVisibleLines: Int
    var maximumHeight: CGFloat

    var body: some View {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let preview = SessionLinkedText(text)
            .font(typography.font)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if lineCount > maximumVisibleLines {
                ScrollView {
                    preview
                }
                .frame(height: maximumHeight)
            } else {
                preview
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

extension View {
    func pendingAskLayout() -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025))
    }
}
