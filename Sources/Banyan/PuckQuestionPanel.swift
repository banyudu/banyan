import BanyanCore
import SwiftUI

/// A pending question, one step per question. Keys: a number picks that
/// option, Return continues or submits.
struct PuckQuestionPanel: View {
    @ObservedObject var session: PuckSession
    let pending: PuckPendingQuestion
    let plan: String?
    let typography: PuckTranscriptTypography
    let takesFocus: Bool
    @State private var questionChoices: [Int: Set<String>] = [:]
    @State private var questionTexts: [Int: String] = [:]
    @State private var questionStep = 0
    @State private var isQuestionPlanExpanded = false
    @State private var hoveredQuestionRow: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        if pending.questions.isEmpty {
            EmptyView()
        } else {
            let step = min(max(questionStep, 0), pending.questions.count - 1)
            let question = pending.questions[step]
            let isFinalStep = step == pending.questions.count - 1
            VStack(alignment: .leading, spacing: 12) {
                header(step: step)
                if let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup(isExpanded: $isQuestionPlanExpanded) {
                        questionPlanPreview(plan)
                            .padding(.top, 6)
                    } label: {
                        Label("Plan", systemImage: "list.bullet.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                questionStem(question)
                if questionRowCount(question) > 10 {
                    ScrollView {
                        questionChoices(question, questionIndex: step)
                    }
                    .frame(height: 300)
                } else {
                    questionChoices(question, questionIndex: step)
                }
                HStack(spacing: 8) {
                    Text(questionHint(question))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 12)
                    if step > 0 {
                        Button("Back") {
                            questionStep = step - 1
                        }
                        .buttonStyle(.banyanBordered)
                        .controlSize(.small)
                    }
                    if isFinalStep {
                        Button(pending.questions.count == 1 ? "Submit answer" : "Submit answers", action: submit)
                            .buttonStyle(.banyanBorderedProminent)
                            .controlSize(.small)
                            .disabled(selections() == nil)
                    } else {
                        Button("Continue") {
                            questionStep = step + 1
                        }
                        .buttonStyle(.banyanBorderedProminent)
                        .controlSize(.small)
                        .disabled(selection(for: question, questionIndex: step) == nil)
                    }
                }
            }
            .pendingAskLayout()
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press, question: question, step: step) }
            .onAppear { if takesFocus { isFocused = true } }
            .onChange(of: session.askFocusRequest) { _, _ in isFocused = true }
            .onChange(of: questionStep) { _, _ in
                hoveredQuestionRow = nil
            }
            .accessibilityIdentifier(AccessibilityID.puckQuestionPanel)
        }
    }

    private func header(step: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Answer needed")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("Question \(step + 1) of \(pending.questions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if pending.questions.count > 1 {
                ProgressView(value: Double(step + 1), total: Double(pending.questions.count))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Question progress")
                    .accessibilityValue("Question \(step + 1) of \(pending.questions.count)")
            }
        }
    }

    private func handle(_ press: KeyPress, question: PuckQuestion, step: Int) -> KeyPress.Result {
        guard isFocused, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        if press.key == .return {
            if step == pending.questions.count - 1 {
                submit()
            } else if selection(for: question, questionIndex: step) != nil {
                questionStep = step + 1
            }
            return .handled
        }
        if let number = Int(press.characters), number >= 1, number <= question.options.count {
            choose(question.options[number - 1].label, for: step, multiple: question.multiple)
            return .handled
        }
        return .ignored
    }

    private func submit() {
        if let selections = selections() {
            session.answer(selections)
        }
    }

    private func questionStem(_ question: PuckQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                SessionLinkedText(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            SessionLinkedText(question.question)
                .font(typography.font)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionChoices(_ question: PuckQuestion, questionIndex: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { optionIndex, option in
                questionChoiceRow(
                    option,
                    number: optionIndex + 1,
                    questionIndex: questionIndex,
                    multiple: question.multiple
                )
            }
            if question.custom {
                customQuestionRow(for: questionIndex, number: question.options.count + 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionHint(_ question: PuckQuestion) -> String {
        let keys = " Press a number to choose, Return to continue."
        switch (question.multiple, question.custom) {
        case (true, true): return "Select one or more answers, or type your own." + keys
        case (true, false): return "Select one or more answers." + keys
        case (false, true): return "Select an answer or type your own." + keys
        case (false, false): return "Select an answer." + keys
        }
    }

    private func questionPlanPreview(_ plan: String) -> some View {
        Group {
            if plan.split(separator: "\n", omittingEmptySubsequences: false).count > 6 {
                ScrollView {
                    planText(plan)
                }
                .frame(height: 100)
            } else {
                planText(plan)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func planText(_ plan: String) -> some View {
        MarkdownText(plan, style: typography.markdownStyle)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionRowCount(_ question: PuckQuestion) -> Int {
        question.options.count + (question.custom ? 1 : 0)
    }

    private func questionChoiceRow(
        _ option: PuckQuestionChoice,
        number: Int,
        questionIndex: Int,
        multiple: Bool
    ) -> some View {
        let rowID = "q\(questionIndex)-o\(number)"
        let isSelected = questionChoices[questionIndex, default: []].contains(option.label)
        let isHighlighted = isSelected || hoveredQuestionRow == rowID
        return Button {
            choose(option.label, for: questionIndex, multiple: multiple)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(isHighlighted ? "›" : " ")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                    .frame(width: 12, alignment: .leading)
                Text("\(number).")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                SessionLinkedText(option.label)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                if !option.description.isEmpty {
                    SessionLinkedText(option.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if multiple {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.55))
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
            if hovering {
                hoveredQuestionRow = rowID
            } else if hoveredQuestionRow == rowID {
                hoveredQuestionRow = nil
            }
        }
        .accessibilityLabel(option.description.isEmpty ? option.label : "\(option.label). \(option.description)")
    }

    private func customQuestionRow(for index: Int, number: Int) -> some View {
        let rowID = "q\(index)-custom"
        let hasAnswer = !(questionTexts[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isHighlighted = hasAnswer || hoveredQuestionRow == rowID
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(isHighlighted ? "›" : " ")
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                .frame(width: 12, alignment: .leading)
            Text("\(number).")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Other answer", text: customAnswerBinding(for: index))
                .textFieldStyle(.plain)
                .font(typography.font)
                .accessibilityLabel("Other answer for question \(index + 1)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onHover { hovering in
            if hovering {
                hoveredQuestionRow = rowID
            } else if hoveredQuestionRow == rowID {
                hoveredQuestionRow = nil
            }
        }
    }

    private func choose(_ label: String, for index: Int, multiple: Bool) {
        var chosen = questionChoices[index] ?? []
        if multiple {
            if !chosen.insert(label).inserted {
                chosen.remove(label)
            }
        } else {
            chosen = [label]
        }
        questionChoices[index] = chosen
        questionTexts[index] = ""
    }

    private func customAnswerBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { questionTexts[index] ?? "" },
            set: { value in
                questionTexts[index] = value
                if !value.isEmpty {
                    questionChoices[index] = []
                }
            }
        )
    }

    private func selection(for question: PuckQuestion, questionIndex: Int) -> PuckQuestionSelection? {
        let text = questionTexts[questionIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if question.custom && !text.isEmpty {
            return PuckQuestionSelection(text: text)
        }
        let chosen = questionChoices[questionIndex] ?? []
        let labels = question.options.map(\.label).filter { chosen.contains($0) }
        guard !labels.isEmpty, question.multiple || labels.count == 1 else { return nil }
        return PuckQuestionSelection(labels: labels)
    }

    private func selections() -> [PuckQuestionSelection]? {
        var answers: [PuckQuestionSelection] = []
        for (index, question) in pending.questions.enumerated() {
            guard let answer = selection(for: question, questionIndex: index) else { return nil }
            answers.append(answer)
        }
        return answers.count == pending.questions.count ? answers : nil
    }
}
