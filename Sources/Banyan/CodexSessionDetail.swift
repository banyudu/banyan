import BanyanCore
import SwiftUI
import UniformTypeIdentifiers

/// This is the App Server client, separate from Puck and the remote-control TUI.
struct CodexSessionDetail: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: CodexSession
    /// The host supplies its rollout preference; disabling keeps existing work actionable.
    var nativeModeEnabled = true
    /// Rollout/fallback policy belongs to the host; this view only offers the action.
    var onOpenCLIFallback: (() -> Void)? = nil
    @State private var followOutput = true
    @State private var historyDocument: CodexHistoryDocument?
    @State private var exportingHistory = false
    @State private var loadingHistory = false
    @State private var historyError: String?
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            timeline
            if !session.state.pendingRequests.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(session.state.pendingRequests, id: \.id.inspectableText) { request in
                            CodexRequestPanel(session: session, request: request)
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 320)
                .background(.bar)
            }
            Divider()
            composer
        }
        .background(.background)
        .accessibilityIdentifier(AccessibilityID.codexSessionDetail)
        .onAppear { promptFocused = true }
        .onChange(of: store.terminalFocusRequestID) { _, _ in promptFocused = true }
        .fileExporter(isPresented: $exportingHistory, document: historyDocument, contentType: .json, defaultFilename: "codex-history") { result in
            if case .failure(let error) = result { historyError = error.localizedDescription }
            historyDocument = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(session.displayTitle, systemImage: "bubble.left.and.bubble.right")
                    .font(.headline).lineLimit(1)
                Spacer()
                if session.state.connection == .connecting { ProgressView().controlSize(.small) }
                if nativeModeEnabled, session.state.connection != .subscribed {
                    Button("Reconnect") { session.reconnect() }
                        .accessibilityIdentifier(AccessibilityID.codexReconnect)
                }
                Button("Open Shell") {
                    store.spawn(cwd: session.cwd, command: "", parentSessionID: session.parentSessionID)
                }
                .accessibilityIdentifier(AccessibilityID.codexOpenShell)
                if let onOpenCLIFallback {
                    Button("Use Codex CLI", action: onOpenCLIFallback)
                        .accessibilityIdentifier("banyan.codex.cli-fallback")
                }
                Button("Save Full History…") { Task { await exportHistory() } }
                    .disabled(!nativeModeEnabled || loadingHistory || session.state.binding.threadID == nil)
            }
            Text(["Codex", session.state.binding.settings.model ?? "Default model", status,
                  session.state.binding.settings.approvalPolicy, session.state.binding.settings.sandbox].joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let message = session.state.connection.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var status: String {
        if session.state.needsAttention { return "Waiting for your response" }
        if session.state.activeTurnID != nil { return "Working" }
        return session.state.lastTurnStatus ?? session.state.runtime.type
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if session.conversation.omittedTurns > 0 || session.conversation.omittedItems > 0 {
                        Text("Display limit: \(session.conversation.omittedTurns) earlier turns and \(session.conversation.omittedItems) items omitted. Save Full History to inspect the server's completed history.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.conversation.turns.isEmpty {
                        ContentUnavailableView(nativeModeEnabled ? "Start a conversation" : "Native Codex is disabled", systemImage: "bubble.left.and.bubble.right",
                            description: Text(nativeModeEnabled ? "Send a prompt to Codex, or open a shell for terminal work." : "Enable Native Codex in Settings, or open a shell for terminal work."))
                    }
                    ForEach(session.conversation.turns) { turn in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Turn \(turn.id)").lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(turn.status)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ForEach(turn.items) { item in CodexTimelineItem(item: item) }
                            if let error = turn.error, error != .null {
                                CodexCodeBlock(text: error.inspectableText).foregroundStyle(.red)
                            }
                            if !turn.diff.isEmpty {
                                if turn.omittedDiffBytes > 0 { omission("Turn diff", bytes: turn.omittedDiffBytes) }
                                DisclosureGroup("Review turn changes") { CodexCodeBlock(text: turn.diff) }
                            }
                        }
                        .accessibilityIdentifier("banyan.codex.turn.\(turn.id)")
                    }
                    if !session.conversation.diagnostics.isEmpty {
                        DisclosureGroup("Protocol details (\(session.conversation.diagnostics.count))") {
                            ForEach(session.conversation.diagnostics) { event in
                                Text(event.method).font(.caption.bold())
                                CodexCodeBlock(text: event.params.inspectableText)
                                if event.omittedBytes > 0 { Text("Event payload shortened for display.").font(.caption) }
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.codexProtocolDetails)
                    }
                    Color.clear.frame(height: 1).id("codex-timeline-end")
                }
                .padding(16)
            }
            .onChange(of: session.conversation.revision) { _, _ in
                if followOutput { proxy.scrollTo("codex-timeline-end", anchor: .bottom) }
            }
            .accessibilityIdentifier(AccessibilityID.codexTimeline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.actionError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let historyError { Text(historyError).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .bottom) {
                if nativeModeEnabled {
                    TextField(session.state.activeTurnID == nil ? "Message Codex" : "Steer the active turn", text: $session.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...6).focused($promptFocused)
                        .onSubmit(send)
                        .accessibilityIdentifier(AccessibilityID.codexMessageField)
                    Button(session.state.activeTurnID == nil ? "Send" : "Steer", action: send)
                        .disabled(!session.canSend)
                        .accessibilityIdentifier(AccessibilityID.codexSend)
                } else {
                    Text("Native Codex is disabled. Existing turns and requests remain available. Enable Native Codex in Settings to send messages.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Button("Interrupt") { Task { await session.interrupt() } }
                    .disabled(session.state.activeTurnID == nil)
                    .accessibilityIdentifier(AccessibilityID.codexInterrupt)
            }
            Toggle("Follow output", isOn: $followOutput).toggleStyle(.checkbox).font(.caption)
        }
        .padding(12)
        .background(.bar)
    }

    private func send() {
        guard nativeModeEnabled else { return }
        Task { await session.sendDraft() }
    }

    private func exportHistory() async {
        loadingHistory = true
        historyError = nil
        defer { loadingHistory = false }
        do {
            let history = try await session.coordinator.read(sessionID: session.id)
            guard let thread = history.objectValue?["thread"]?.objectValue,
                  thread["id"]?.stringValue == session.state.binding.threadID,
                  case .array = thread["turns"] else {
                throw CodexAppServerError.protocolViolation("Codex did not return the requested thread history")
            }
            historyDocument = CodexHistoryDocument(data: Data(history.inspectableText.utf8))
            exportingHistory = true
        } catch { historyError = error.localizedDescription }
    }
}

private struct CodexHistoryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private func omission(_ label: String, bytes: Int) -> some View {
    Text("\(label): \(bytes) earlier bytes omitted from display. Save Full History for the server's completed history.")
        .font(.caption).foregroundStyle(.secondary)
}

struct CodexTimelineItem: View {
    let item: CodexConversationItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption.bold())
                if let status = item.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if item.omittedOutputBytes > 0 { omission("Output", bytes: item.omittedOutputBytes) }
            if item.omittedPayloadBytes > 0 {
                Text("Item content shortened to the display budget. Save Full History to inspect completed history.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch item.type {
            case "agentMessage", "plan": MarkdownText(item.text)
            case "userMessage": Text(item.text).textSelection(.enabled)
            case "reasoning":
                DisclosureGroup("Reasoning summary") { Text(item.text).textSelection(.enabled) }
            case "commandExecution":
                CodexCodeBlock(text: item.text)
                if let cwd = item.value.objectValue?["cwd"]?.stringValue {
                    Text(cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !item.readableOutput.isEmpty { CodexCodeBlock(text: item.readableOutput) }
                if let exit = item.value.objectValue?["exitCode"], exit != .null {
                    Text("Exit code: \(exit.inspectableText)").font(.caption)
                }
                details
            case "fileChange":
                ForEach(Array((item.value.objectValue?["changes"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, change in
                    let fields = change.objectValue ?? [:]
                    let kind = fields["kind"]?.objectValue?["type"]?.stringValue ?? fields["kind"]?.stringValue ?? "change"
                    Label("\(fields["path"]?.stringValue ?? "Unknown path") · \(kind)", systemImage: "doc.text")
                        .font(.callout).textSelection(.enabled)
                    CodexCodeBlock(text: fields["diff"]?.stringValue ?? change.inspectableText)
                }
                if !item.readableOutput.isEmpty { CodexCodeBlock(text: item.readableOutput) }
                details
            case "mcpToolCall", "dynamicToolCall", "collabToolCall", "collabAgentToolCall", "functionCallOutput", "webSearch":
                Text(item.text).textSelection(.enabled)
                if !item.toolOutput.isEmpty { CodexCodeBlock(text: item.toolOutput) }
                details
            default:
                // Unknown items are never dropped or force-decoded as a known type.
                CodexCodeBlock(text: item.value.inspectableText)
                if !item.readableOutput.isEmpty { CodexCodeBlock(text: item.readableOutput) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("banyan.codex.item.\(item.id)")
    }

    private var label: String {
        switch item.type {
        case "agentMessage": return "Codex"
        case "userMessage": return "You"
        case "commandExecution": return "Command"
        case "fileChange": return "File changes"
        default: return item.type
        }
    }

    private var details: some View {
        DisclosureGroup("Item details") { CodexCodeBlock(text: item.value.inspectableText) }
            .font(.caption)
    }
}

struct CodexCodeBlock: View {
    let text: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(CodexConversationText.plain(text))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: 30, maxHeight: 220)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct CodexRequestPanel: View {
    @ObservedObject var session: CodexSession
    let request: CodexServerRequest
    @State private var answers: [String: String] = [:]
    private var presentation: CodexConversationRequest { .init(request) }
    private var submitted: Bool { session.submittedRequestIDs.contains(request.id.inspectableText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: "hand.raised").font(.headline)
            Text("Turn \(request.params.objectValue?["turnId"]?.stringValue ?? "unknown")")
                .font(.caption).foregroundStyle(.secondary)
            if let reason = request.params.objectValue?["reason"]?.stringValue { Text(reason).textSelection(.enabled) }
            if let command = request.params.objectValue?["command"]?.stringValue { CodexCodeBlock(text: command) }
            if let network = request.params.objectValue?["networkApprovalContext"], network != .null {
                CodexCodeBlock(text: network.inspectableText)
            }
            if let item = associatedItem, item.type == "fileChange" { CodexTimelineItem(item: item) }
            DisclosureGroup("Request details") { CodexCodeBlock(text: request.params.inspectableText) }
            if submitted {
                Text("Response sent. Waiting for Codex to resolve this request…").font(.callout)
            } else if presentation.isApproval {
                ViewThatFits(in: .horizontal) {
                    HStack { approvalButtons }
                    VStack(alignment: .leading) { approvalButtons }
                }
                if presentation.decisions.isEmpty {
                    Text("This request offers decisions Banyan does not support. Inspect its details or interrupt the turn.")
                    Button("Reject Unsupported Request") { session.rejectUnsupported(request) }
                }
            } else if presentation.isInput {
                ForEach(presentation.questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.header).font(.subheadline.bold())
                        Text(question.question)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            if let label = option.objectValue?["label"]?.stringValue {
                                Button { answers[question.id] = label } label: {
                                    Label(label, systemImage: answers[question.id] == label ? "checkmark.circle.fill" : "circle")
                                }
                                if let description = option.objectValue?["description"]?.stringValue {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if question.allowsOther || question.options.isEmpty {
                            if question.isSecret {
                                SecureField("Answer", text: answerBinding(question.id)).textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Answer", text: answerBinding(question.id)).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                HStack {
                    Button("Answer") { session.answer(request, answers: answers) }
                        .disabled((try? presentation.inputReply(answers)) == nil)
                    Button("Skip Input") { session.skipInput(request) }
                    Button("Cancel Turn") { Task { await session.cancelInput(request) } }
                }
            } else {
                Text("Inspect this request before rejecting it or interrupting the turn.")
                Button("Reject Unsupported Request") { session.rejectUnsupported(request) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("banyan.codex.request.\(request.id.inspectableText)")
    }

    @ViewBuilder private var approvalButtons: some View {
        ForEach(presentation.decisions, id: \.rawValue) { decision in
            Button(decision.label) { session.respond(request, decision: decision) }
                .accessibilityIdentifier("banyan.codex.request-action.\(decision.rawValue)")
        }
    }

    private var associatedItem: CodexConversationItem? {
        let fields = request.params.objectValue
        return session.conversation.turns.first { $0.id == fields?["turnId"]?.stringValue }?
            .items.first { $0.id == fields?["itemId"]?.stringValue }
    }
    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }
}
