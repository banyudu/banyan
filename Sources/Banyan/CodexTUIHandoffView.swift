import BanyanCore
import SwiftUI

/// Explicit ownership guidance for legacy CLIs, beside the terminal they own.
struct CodexTUIHandoffView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var session: TerminalSession
    @State private var busy = false

    private var observation: CodexTUIOwnershipObservation? {
        guard let value = store.codexTUIOwnership[session.id], value.threadID == session.agentSessionID else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex CLI ownership").font(.headline)
            if let observation {
                Text(observation.state.title).font(.subheadline)
                Text("Checked \(observation.observedAt.formatted(date: .abbreviated, time: .standard)). Check again after terminal activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(observation?.state.message
                ?? "This interactive CLI may hold the thread's writer while idle. Prepare Remote Handoff before exiting so its tmux pane survives. Terminal detach alone does not enable ChatGPT Remote reconnect.")
                .font(.callout)
                .textSelection(.enabled)
            HStack {
                Button("Prepare Remote Handoff") { perform(check: false) }
                Button("Check CLI Exit") { perform(check: true) }
            }
            .disabled(busy)
            if let id = session.agentSessionID {
                Text("Thread: \(id)").font(.caption).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func perform(check: Bool) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await store.codexTUIHandoff(id: session.id, checkOnly: check) }
            catch { store.codexSessionError = error.localizedDescription }
        }
    }
}
