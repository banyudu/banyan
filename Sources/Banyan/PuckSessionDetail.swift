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
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            if let pending = session.pendingApproval {
                Divider()
                approvalPanel(pending)
            }
            if let pending = session.pendingQuestion {
                Divider()
                if let plan = session.questionPlan {
                    ScrollView {
                        Text(plan)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                    .padding(16)
                }
                questionPanel(pending)
            }
            Divider()
            composer
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
        }
        .accessibilityIdentifier(AccessibilityID.puckSessionDetail)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let provider = session.agentProvider {
                AgentProviderIcon(provider: provider, helpText: session.agentRuntimeIdentityLabel)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(runtimeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Who runs the session and where it stands, e.g. "Puck · codex · work · idle".
    private var runtimeSummary: String {
        let binding = session.binding
        return ["Puck", binding.provider, binding.model, binding.account, session.position]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var transcript: some View {
        let rendered = session.renderedEvents
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(rendered) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.kind.replacingOccurrences(of: "_", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(event.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(event.id)
                    }
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .hidesVerticalScroller()
            .overlay {
                if rendered.isEmpty {
                    emptyTranscript
                }
            }
            .onChange(of: rendered.last?.id) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 8) {
            Label("Approval needed: \(pending.tool)", systemImage: "hand.raised")
                .font(.headline)
            ScrollView {
                Text(pending.arguments)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            HStack(spacing: 8) {
                Button("Approve") {
                    session.decide("approve")
                }
                .buttonStyle(.banyanBorderedProminent)
                Button("Approve for Session") {
                    session.decide("session")
                }
                .buttonStyle(.banyanBordered)
                Button("Deny") {
                    session.decide("deny")
                }
                .buttonStyle(.banyanBordered)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func questionPanel(_ pending: PuckPendingQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Answer needed", systemImage: "questionmark.bubble")
                .font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(pending.questions.enumerated()), id: \.offset) { index, question in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(question.header)
                                .font(.subheadline.bold())
                            Text(question.question)
                            ForEach(question.options, id: \.label) { option in
                                Button {
                                    choose(option.label, for: index, multiple: question.multiple)
                                } label: {
                                    Label(
                                        "\(option.label) — \(option.description)",
                                        systemImage: questionChoices[index, default: []].contains(option.label)
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            if question.custom {
                                TextField("Other answer", text: customAnswerBinding(for: index))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            Button("Answer") {
                if let selections = selections(for: pending) {
                    session.answer(selections)
                }
            }
            .buttonStyle(.banyanBorderedProminent)
            .controlSize(.small)
            .disabled(selections(for: pending) == nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.daemonError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField("Message", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .focused($isPromptFocused)
                    .onSubmit(send)
                    .accessibilityIdentifier(AccessibilityID.puckSessionMessageField)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.banyanBorderless)
                .font(.system(size: 20))
                .help(session.turnUnavailableReason ?? "Send")
                .disabled(!canSend)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var canSend: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && session.turnUnavailableReason == nil && !session.admissionTurnInFlight
    }

    private func send() {
        guard canSend else { return }
        session.send(session.draft)
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

    private func selections(for pending: PuckPendingQuestion) -> [PuckQuestionSelection]? {
        var answers: [PuckQuestionSelection] = []
        for (index, question) in pending.questions.enumerated() {
            let text = questionTexts[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if question.custom && !text.isEmpty {
                answers.append(PuckQuestionSelection(text: text))
                continue
            }
            let chosen = questionChoices[index] ?? []
            let labels = question.options.map(\.label).filter { chosen.contains($0) }
            guard !labels.isEmpty, question.multiple || labels.count == 1 else { return nil }
            answers.append(PuckQuestionSelection(labels: labels))
        }
        return answers.count == pending.questions.count ? answers : nil
    }
}
