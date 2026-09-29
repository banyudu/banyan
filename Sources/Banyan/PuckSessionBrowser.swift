import BanyanCore
import Foundation
import SwiftUI

struct PuckSessionProject: Equatable, Sendable {
    let id: String
    let title: String
}

@MainActor
final class PuckSessionBrowser: ObservableObject {
    @Published private(set) var sessions: [PuckSessionSummary] = []
    @Published private(set) var projectsBySessionID: [String: PuckSessionProject] = [:]
    @Published private(set) var selectedID: String?
    @Published private(set) var selectedSummary: PuckSessionSummary?
    @Published private(set) var events: [PuckSessionEvent] = []
    @Published private(set) var error: String?
    @Published private(set) var creationError: String?
    @Published private(set) var isConnecting = false
    @Published var showingNew = false

    private let client = PuckDaemonClient()
    private let homeDirectory: String
    private let environment: [String: String]
    private var connection: PuckDaemonConnection?
    private var generation = 0
    private var listGeneration = 0

    var renderedEvents: [PuckRenderedEvent] { PuckTranscript.render(events) }

    init(homeDirectory: String = NSHomeDirectory(),
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory
        self.environment = environment
    }

    func refresh() {
        listGeneration += 1
        let currentListGeneration = listGeneration
        let client = self.client
        let homeDirectory = self.homeDirectory
        let environment = self.environment
        Task.detached(priority: .utility) {
            do {
                let sessions = try client.list()
                var projectsByWorkspace: [String: PuckSessionProject] = [:]
                var projectsBySessionID: [String: PuckSessionProject] = [:]
                for session in sessions {
                    if projectsByWorkspace[session.workspace] == nil {
                        let context = SessionDisplayLabel.context(
                            cwd: session.workspace,
                            homeDirectory: homeDirectory,
                            environment: environment
                        )
                        projectsByWorkspace[session.workspace] = PuckSessionProject(
                            id: context.groupID, title: context.groupTitle
                        )
                    }
                    projectsBySessionID[session.id] = projectsByWorkspace[session.workspace]
                }
                let projects = projectsBySessionID
                await MainActor.run {
                    guard self.listGeneration == currentListGeneration else { return }
                    self.sessions = sessions
                    self.projectsBySessionID = projects
                    self.error = nil
                }
            } catch {
                await MainActor.run {
                    if self.listGeneration == currentListGeneration {
                        self.error = error.localizedDescription
                    }
                }
            }
        }
    }

    func select(_ id: String) {
        detach()
        selectedID = id
        selectedSummary = sessions.first { $0.id == id }
        events = []
        isConnecting = true
        let currentGeneration = generation
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                let (connection, attached) = try client.attach(id)
                let replayed = try client.replay(id, initial: attached.batch)
                let shouldRead = await MainActor.run { () -> Bool in
                    guard self.generation == currentGeneration else { return false }
                    self.connection = connection
                    self.selectedSummary = attached.summary
                    self.events = replayed
                    self.isConnecting = false
                    self.error = nil
                    return true
                }
                guard shouldRead else { connection.disconnect(); return }
                var cursor = replayed.last?.cursor ?? attached.batch.cursor
                while let nextEvents = try client.receive(connection, session: id, after: cursor) {
                    if let last = nextEvents.last { cursor = last.cursor }
                    guard !nextEvents.isEmpty else { continue }
                    let keepReading = await MainActor.run { () -> Bool in
                        guard self.generation == currentGeneration else { return false }
                        // The daemon cursor is authoritative. Replayed and live
                        // events meet at this boundary without duplicate rows.
                        self.events.append(contentsOf: nextEvents.filter {
                            $0.cursor > (self.events.last?.cursor ?? 0)
                        })
                        return true
                    }
                    if !keepReading { break }
                    if nextEvents.contains(where: { Self.summaryEvents.contains($0.kind) }) {
                        let summary = try client.get(id)
                        await MainActor.run {
                            if self.generation == currentGeneration { self.selectedSummary = summary }
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.generation == currentGeneration else { return }
                    self.error = error.localizedDescription
                    self.isConnecting = false
                }
            }
        }
    }

    func detach() {
        generation += 1
        connection?.disconnect()
        connection = nil
        selectedID = nil
        selectedSummary = nil
        events = []
        isConnecting = false
    }

    func create(provider: String, account: String?, model: String?, workspace: String,
                prompt: String?) {
        creationError = nil
        let client = self.client
        let id = UUID().uuidString.lowercased()
        let homeDirectory = self.homeDirectory
        let environment = self.environment
        Task.detached(priority: .userInitiated) {
            do {
                let summary = try client.create(id: id, provider: provider, account: account,
                                                model: model, workspace: workspace)
                let context = SessionDisplayLabel.context(
                    cwd: summary.workspace, homeDirectory: homeDirectory, environment: environment
                )
                let project = PuckSessionProject(id: context.groupID, title: context.groupTitle)
                await MainActor.run {
                    self.listGeneration += 1
                    self.sessions.append(summary)
                    self.sessions.sort { $0.id < $1.id }
                    self.projectsBySessionID[summary.id] = project
                    self.select(summary.id)
                }
                if let prompt, !prompt.isEmpty { try client.turn(id, prompt: prompt) }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.creationError = error.localizedDescription
                }
            }
        }
    }

    func dismissCreationError() {
        creationError = nil
    }

    func createSibling() {
        guard let current = selectedSummary else {
            showingNew = true
            return
        }
        create(provider: current.provider, account: current.account,
               model: current.model, workspace: current.workspace, prompt: nil)
    }

    func turn(_ prompt: String) {
        guard let id = selectedID, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do { try client.turn(id, prompt: prompt) }
            catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    func decide(_ decision: String) {
        guard let id = selectedID, let pending = selectedSummary?.pendingApproval else { return }
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                try client.decide(id, callID: pending.callID, decision: decision)
                let summary = try client.get(id)
                await MainActor.run {
                    if self.selectedID == id { self.selectedSummary = summary }
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func answer(_ selections: [PuckQuestionSelection]) {
        guard let id = selectedID, let pending = selectedSummary?.pendingQuestion else { return }
        let client = self.client
        let currentGeneration = generation
        Task.detached(priority: .userInitiated) {
            do {
                try client.answer(id, callID: pending.callID, selections: selections)
            } catch {
                await MainActor.run {
                    if self.generation == currentGeneration { self.error = error.localizedDescription }
                }
            }
        }
    }

    nonisolated private static let summaryEvents: Set<String> = [
        "turn_done", "turn_error", "approval_pending", "approval_decided",
        "blocked_on_question", "question_answered", "hibernated",
    ]
}

struct PuckSessionSidebar: View {
    @ObservedObject var browser: PuckSessionBrowser
    @State private var provider = "codex"
    @State private var account = ""
    @State private var model = ""
    @State private var workspace = NSHomeDirectory()
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            List(browser.sessions, id: \.id) { session in
                Button {
                    browser.select(session.id)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.id).lineLimit(1)
                        Text("\(session.position) · \(session.provider)/\(session.model)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .listRowBackground(browser.selectedID == session.id ? Color.accentColor.opacity(0.16) : Color.clear)
            }
            .listStyle(.sidebar)
            HStack {
                Button("New") { browser.showingNew = true }
                Button("Refresh") { browser.refresh() }
                Spacer()
            }
            .padding(8)
        }
        .onAppear { browser.refresh() }
        .sheet(isPresented: $browser.showingNew) {
            Form {
                Picker("Provider", selection: $provider) {
                    Text("Codex").tag("codex")
                    Text("OpenCode Go").tag("opencode-go")
                    Text("Anthropic API (billed)").tag("anthropic")
                    Text("Gemini AI Studio API (billed)").tag("gemini")
                }
                TextField(["anthropic", "gemini"].contains(provider) ? "API-key account label" : "Account label (optional)", text: $account)
                TextField(["anthropic", "gemini"].contains(provider) ? "API model ID" : "Model (optional)", text: $model)
                TextField("Workspace", text: $workspace)
                TextField("First prompt (optional)", text: $prompt)
                HStack {
                    Button("Cancel") { browser.showingNew = false }
                    Button("Create") {
                        browser.create(provider: provider,
                                       account: account.isEmpty ? nil : account,
                                       model: model.isEmpty ? nil : model,
                                       workspace: NSString(string: workspace).expandingTildeInPath,
                                       prompt: prompt.isEmpty ? nil : prompt)
                        browser.showingNew = false
                    }
                    .disabled(workspace.isEmpty || (["anthropic", "gemini"].contains(provider) && (model.isEmpty || account.isEmpty)))
                }
            }
            .padding()
            .frame(width: 460)
        }
    }
}

struct PuckSessionDetail: View {
    @ObservedObject var browser: PuckSessionBrowser
    @State private var prompt = ""
    @State private var questionChoices: [Int: Set<String>] = [:]
    @State private var questionTexts: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summary = browser.selectedSummary {
                HStack {
                    VStack(alignment: .leading) {
                        Text(summary.id).font(.headline)
                        Text("\(summary.provider)/\(summary.model) · \(summary.account) · \(summary.position)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Detach") { browser.detach() }
                }
                .padding()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(browser.renderedEvents) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.kind.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(event.text).font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(event.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: browser.events.count) { _, _ in
                        if let last = browser.renderedEvents.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let pending = summary.pendingApproval {
                    VStack(alignment: .leading) {
                        Text("Approval needed: \(pending.tool)").font(.headline)
                        Text(pending.arguments).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        HStack {
                            Button("Approve") { browser.decide("approve") }
                            Button("Deny") { browser.decide("deny") }
                            Button("Approve for session") { browser.decide("session") }
                        }
                    }
                    .padding()
                }
                if let pending = summary.pendingQuestion {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Answer needed").font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(pending.questions.enumerated()), id: \.offset) { index, question in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(question.header).font(.subheadline.bold())
                                        Text(question.question)
                                        ForEach(question.options, id: \.label) { option in
                                            Button {
                                                var chosen = questionChoices[index] ?? []
                                                if question.multiple {
                                                    if !chosen.insert(option.label).inserted { chosen.remove(option.label) }
                                                } else {
                                                    chosen = [option.label]
                                                }
                                                questionChoices[index] = chosen
                                                questionTexts[index] = ""
                                            } label: {
                                                Label("\(option.label) — \(option.description)",
                                                      systemImage: questionChoices[index, default: []].contains(option.label)
                                                        ? "checkmark.circle.fill" : "circle")
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        if question.custom {
                                            TextField("Other answer", text: Binding(
                                                get: { questionTexts[index] ?? "" },
                                                set: { value in
                                                    questionTexts[index] = value
                                                    if !value.isEmpty { questionChoices[index] = [] }
                                                }
                                            ))
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                        Button("Answer") {
                            if let selections = selections(for: pending) { browser.answer(selections) }
                        }
                        .disabled(selections(for: pending) == nil)
                    }
                    .padding()
                }
                HStack {
                    TextField("Message", text: $prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .onSubmit(send)
                    Button("Send", action: send).disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            } else if browser.isConnecting {
                ProgressView("Attaching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select a puck session", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = browser.error {
                Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }
        }
        .onChange(of: browser.selectedID) { _, _ in
            questionChoices = [:]
            questionTexts = [:]
        }
        .onChange(of: browser.selectedSummary?.pendingQuestion?.callID) { _, _ in
            questionChoices = [:]
            questionTexts = [:]
        }
        .onDisappear { browser.detach() }
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        browser.turn(text)
        prompt = ""
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
