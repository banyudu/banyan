import BanyanCore
import SwiftUI

/// The detail pane of a `PuckSession`: the daemon's transcript, its pending
/// approval or question, and a message field. The session follows its event
/// stream only while this pane is on screen; a shared daemon watch keeps the
/// sidebar current and reports human activity.
struct PuckSessionDetail: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: PuckSession
    @State private var questionChoices: [Int: Set<String>] = [:]
    @State private var questionTexts: [Int: String] = [:]
    @State private var questionStep = 0
    @State private var isQuestionPlanExpanded = false
    @State private var hoveredQuestionRow: String?
    @State private var approvalSelection: PuckApprovalChoice = .approve
    @State private var promptHistory = PuckPromptHistory()
    @State private var isFollowingLatest = true
    @FocusState private var isPromptFocused: Bool

    private let transcriptEndID = "puck-transcript-end"

    var body: some View {
        let timeline = session.timeline
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = session.cancellationNotice {
                Divider()
                cancellationBanner(notice)
            }
            Divider()
            transcript(timeline)
            if let pending = session.pendingApproval, !session.decisionInFlight {
                Divider()
                approvalPanel(pending)
            }
            if let pending = session.pendingQuestion, !session.answerInFlight {
                Divider()
                questionPanel(pending, plan: session.questionPlan)
            }
            Divider()
            composer(usage: timeline.usage)
        }
        .onAppear {
            session.startFollowing()
            DispatchQueue.main.async {
                isPromptFocused = true
            }
        }
        .onDisappear {
            session.stopFollowing()
        }
        // The shortcut that focuses a terminal pane focuses this pane's input.
        .onChange(of: store.terminalFocusRequestID) { _, _ in
            isPromptFocused = true
        }
        .onChange(of: session.pendingQuestion?.callID) { _, _ in
            questionChoices = [:]
            questionTexts = [:]
            questionStep = 0
            isQuestionPlanExpanded = false
            hoveredQuestionRow = nil
        }
        .onChange(of: session.pendingApproval?.callID) { _, _ in
            approvalSelection = .approve
        }
        .accessibilityIdentifier(AccessibilityID.puckSessionDetail)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(runtimeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            PuckTurnStatusBadge(phase: session.turnPhase)
            if session.turnPhase.isTurnActive {
                Button {
                    session.cancel()
                } label: {
                    Label(
                        session.cancelInFlight ? "Stopping…" : "Stop",
                        systemImage: session.cancelInFlight ? "hourglass" : "stop.circle"
                    )
                }
                .buttonStyle(.banyanBordered)
                .controlSize(.small)
                .disabled(!session.canCancelTurn)
                .help("Stop this turn without closing the session or its history")
                .accessibilityIdentifier(AccessibilityID.puckStopTurn)
            }
            switch session.followState {
            case .connecting:
                ProgressView()
                    .controlSize(.small)
                    .help("Attaching to puckd")
            case .lost:
                Button {
                    session.startFollowing()
                } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
                .help("Attach to this session in puckd again")
            case .following, .stopped:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// Who runs the session, e.g. "Puck · codex · gpt-5.5 · default".
    private var runtimeSummary: String {
        let binding = session.binding
        return ["Puck", binding.provider, binding.model, binding.account]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func transcript(_ timeline: PuckTimeline) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if session.nextHistoryCursor != nil {
                        HStack {
                            Spacer()
                            Button {
                                isFollowingLatest = false
                                session.loadOlderHistory()
                            } label: {
                                if session.historyLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("Load earlier messages", systemImage: "clock.arrow.circlepath")
                                }
                            }
                            .buttonStyle(.banyanBorderless)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .disabled(session.historyLoading)
                            .accessibilityIdentifier(AccessibilityID.puckLoadOlderMessages)
                            Spacer()
                        }
                    }
                    PuckTimelineRows(items: timeline.items)
                    if !timeline.notices.isEmpty {
                        PuckTimelineNotices(notices: timeline.notices)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(transcriptEndID)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    PuckTranscriptScrollObserver { following in
                        isFollowingLatest = following
                    }
                }
            }
            .scrollIndicators(.hidden)
            .hidesVerticalScroller()
            .accessibilityIdentifier(AccessibilityID.puckTimeline)
            .overlay {
                if timeline.items.isEmpty && timeline.notices.isEmpty {
                    emptyTranscript
                }
            }
            .overlay(alignment: .bottom) {
                if !isFollowingLatest && !timeline.items.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            isFollowingLatest = true
                            proxy.scrollTo(transcriptEndID, anchor: .bottom)
                        }
                        if !session.historyItems.isEmpty {
                            session.loadLatestHistory()
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.banyanBordered)
                    .controlSize(.small)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier(AccessibilityID.puckLatestMessages)
                }
            }
            .onAppear {
                isFollowingLatest = true
                DispatchQueue.main.async {
                    proxy.scrollTo(transcriptEndID, anchor: .bottom)
                }
            }
            .onChange(of: timeline) { _, next in
                guard isFollowingLatest, !next.items.isEmpty else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(transcriptEndID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cancellationBanner(_ notice: String) -> some View {
        Label(notice, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .accessibilityIdentifier(AccessibilityID.puckCancellationNotice)
    }

    private func usageSummary(_ usage: PuckUsage) -> String {
        let total = usage.total
        let cache = total.cachedInputTokens > 0
            ? " · \(total.cachedInputTokens.formatted()) cached"
            : ""
        return "\(total.inputTokens.formatted()) in · \(total.outputTokens.formatted()) out\(cache)"
    }

    @ViewBuilder
    private var emptyTranscript: some View {
        switch session.followState {
        case .connecting:
            ProgressView("Attaching…")
        case .lost:
            ContentUnavailableView(
                "Disconnected from puckd",
                systemImage: "bolt.horizontal.circle",
                description: Text("The session is still in puckd. Reconnect to follow it again.")
            )
        case .following, .stopped:
            ContentUnavailableView(
                "No Messages Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Send a message to start the first turn.")
            )
        }
    }

    private func approvalPanel(_ pending: PuckPendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Would you like to approve this action?")
                    .font(.callout.weight(.semibold))
                Text(pending.tool)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !pending.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                quietCodePreview(pending.arguments, maximumVisibleLines: 6, maximumHeight: 140)
            }
            VStack(spacing: 2) {
                ForEach(Array(PuckApprovalChoice.allCases.enumerated()), id: \.element) { index, choice in
                    approvalChoiceRow(choice, number: index + 1)
                }
            }
        }
        .pendingAskLayout()
    }

    private func approvalChoiceRow(_ choice: PuckApprovalChoice, number: Int) -> some View {
        let isSelected = approvalSelection == choice
        return Button {
            approvalSelection = choice
            session.decide(choice.rawValue)
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
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { approvalSelection = choice }
        }
        .accessibilityLabel(choice.label)
    }

    @ViewBuilder
    private func questionPanel(_ pending: PuckPendingQuestion, plan: String?) -> some View {
        if pending.questions.isEmpty {
            EmptyView()
        } else {
            let step = min(max(questionStep, 0), pending.questions.count - 1)
            let question = pending.questions[step]
            let isFinalStep = step == pending.questions.count - 1
            VStack(alignment: .leading, spacing: 12) {
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
                        Button(pending.questions.count == 1 ? "Submit answer" : "Submit answers") {
                            if let selections = selections(for: pending) {
                                session.answer(selections)
                            }
                        }
                        .buttonStyle(.banyanBorderedProminent)
                        .controlSize(.small)
                        .disabled(selections(for: pending) == nil)
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
            .onChange(of: questionStep) { _, _ in
                hoveredQuestionRow = nil
            }
        }
    }

    private func questionStem(_ question: PuckQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.body)
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
        switch (question.multiple, question.custom) {
        case (true, true): "Select one or more answers, or type your own."
        case (true, false): "Select one or more answers."
        case (false, true): "Select an answer or type your own."
        case (false, false): "Select an answer."
        }
    }

    private func questionPlanPreview(_ plan: String) -> some View {
        Group {
            if planLineCount(plan) > 6 {
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
        MarkdownText(plan, style: .comment)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planLineCount(_ plan: String) -> Int {
        plan.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private func questionRowCount(_ question: PuckQuestion) -> Int {
        question.options.count + (question.custom ? 1 : 0)
    }

    @ViewBuilder
    private func quietCodePreview(_ text: String, maximumVisibleLines: Int, maximumHeight: CGFloat) -> some View {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let preview = Text(text)
            .font(.system(.caption, design: .monospaced))
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
                Text(option.label)
                    .font(.callout.weight(isSelected ? .medium : .regular))
                if !option.description.isEmpty {
                    Text(option.description)
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
        .buttonStyle(.plain)
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
                .font(.callout)
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

    private func composer(usage: PuckUsage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.daemonError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    TextField("Ask Puck to do anything", text: promptBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...8)
                        .focused($isPromptFocused)
                        .onSubmit(send)
                        .onKeyPress(phases: .down) { press in
                            guard !press.modifiers.contains(.command),
                                  !press.modifiers.contains(.option),
                                  !press.modifiers.contains(.control),
                                  !press.modifiers.contains(.shift) else { return .ignored }
                            switch press.key {
                            case .upArrow: return recallPreviousPrompt()
                            case .downArrow: return recallNextPrompt()
                            default: return .ignored
                            }
                        }
                        .help("Use ↑ and ↓ to recall sent messages")
                        .accessibilityIdentifier(AccessibilityID.puckSessionMessageField)
                }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.banyanBorderless)
                .font(.system(size: 20))
                .help(session.turnUnavailableReason ?? "Send")
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isPromptFocused ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            }
            .animation(.easeOut(duration: 0.12), value: isPromptFocused)

            HStack(spacing: 12) {
                Text(session.turnUnavailableReason ?? "Return to send")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if let usage {
                    Label(usageSummary(usage), systemImage: "chart.bar")
                        .accessibilityIdentifier(AccessibilityID.puckUsage)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.turnUnavailableReason == nil && !session.admissionTurnInFlight
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { session.draft },
            set: { value in
                promptHistory.reset()
                session.draft = value
            }
        )
    }

    private var promptHistoryEntries: [String] {
        session.timeline.items.reversed().compactMap { item in
            guard item.role == .user, case .user(let text) = item.content else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func recallPreviousPrompt() -> KeyPress.Result {
        guard promptHistory.isBrowsing
                || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let prompt = promptHistory.previous(currentDraft: session.draft, prompts: promptHistoryEntries)
        else { return .ignored }
        session.draft = prompt
        return .handled
    }

    private func recallNextPrompt() -> KeyPress.Result {
        guard let prompt = promptHistory.next() else { return .ignored }
        session.draft = prompt
        return .handled
    }

    private func send() {
        guard canSend else { return }
        session.send(session.draft)
        promptHistory.reset()
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

    private func selections(for pending: PuckPendingQuestion) -> [PuckQuestionSelection]? {
        var answers: [PuckQuestionSelection] = []
        for (index, question) in pending.questions.enumerated() {
            guard let answer = selection(for: question, questionIndex: index) else { return nil }
            answers.append(answer)
        }
        return answers.count == pending.questions.count ? answers : nil
    }
}

private enum PuckApprovalChoice: String, CaseIterable {
    case approve
    case session
    case deny

    var label: String {
        switch self {
        case .approve: "Yes, proceed"
        case .session: "Yes, and don't ask again for this tool in this session"
        case .deny: "No, continue without running it"
        }
    }
}

private extension View {
    func pendingAskLayout() -> some View {
        padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.025))
    }
}
